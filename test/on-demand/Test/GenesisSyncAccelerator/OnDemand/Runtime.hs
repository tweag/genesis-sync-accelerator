{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.OnDemand.Runtime (tests) where

import Control.Concurrent.Class.MonadSTM.Strict.TVar.Checked (readTVarIO)
import Control.Monad ((>=>))
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (ToJSON (..), decode, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Proxy (Proxy (..))
import qualified Data.Text.Encoding as Encoding
import GHC.Conc (atomically)
import GenesisSyncAccelerator.OnDemand
  ( OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandState (..)
  , OnDemandTip (..)
  , newOnDemandRuntime
  , readOnDemandTip
  )
import GenesisSyncAccelerator.RemoteStorage (RemoteTipInfo (..))
import GenesisSyncAccelerator.Types (StandardBlock)
import Ouroboros.Consensus.Block
  ( BlockNo (..)
  , ConvertRawHash (fromRawHash, toRawHash)
  , SlotNo (..)
  )
import Ouroboros.Consensus.Cardano.Block (CardanoBlock, CardanoEras, StandardCrypto)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (OneEraHash)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkInfo (..)
  , ChunkSize (..)
  )
import System.FS.IO (HandleIO)
import System.FilePath (takeDirectory, (</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Orphans ()
import Test.GenesisSyncAccelerator.Types
  ( ConfigFile (..)
  , PartialOnDemandConfig (..)
  , ServerFolder (..)
  , TmpDir (..)
  )
import Test.GenesisSyncAccelerator.Utilities
  ( getTopLevelConfigFilePath
  , ioQuickly
  , mkFullConfig
  , testWithFileServer
  )
import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

----------------------------- Generators and properties -----------------------------
instance Arbitrary (OneEraHash (CardanoEras StandardCrypto)) where
  arbitrary = do
    bytes <- BS.pack <$> vectorOf 32 arbitrary
    return $ fromRawHash (Proxy @(CardanoBlock StandardCrypto)) bytes

instance Arbitrary RemoteTipInfo where
  arbitrary = do
    slot <- arbitrary
    blockNo <- arbitrary
    hash <- arbitrary @(OneEraHash (CardanoEras StandardCrypto))
    return $
      RemoteTipInfo
        { rtiSlot = slot
        , rtiBlockNo = blockNo
        , rtiHashBytes = toRawHash (Proxy @(CardanoBlock StandardCrypto)) hash
        }

prop_newOnDemandRuntimeContainsConfigInfoAsGiven :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeContainsConfigInfoAsGiven partialConfig@PartialOnDemandConfig{..} =
  ioQuickly $
    checkFromConfig partialConfig $ \original -> do
      recovered <- odrConfig <$> newOnDemandRuntime original
      return $
        conjoin
          [ odcChunkInfo recovered === podcChunkInfo
          , odcMaxCachedChunks recovered === podcMaxCachedChunks
          , odcRemote recovered === odcRemote original
          , odcPrefetchAhead recovered === podcPrefetchAhead
          ]

prop_newOnDemandRuntimeStartsWithEmptyCachedChunks :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithEmptyCachedChunks partialConfig =
  ioQuickly $
    checkFromConfig partialConfig $ \config -> do
      runtime <- newOnDemandRuntime config
      chunks <- odsCachedChunks <$> readTVarIO (odrState runtime)
      return $ property $ null chunks

prop_newOnDemandRuntimeStartsWithEmptyUsageOrder :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithEmptyUsageOrder partialConfig =
  ioQuickly $
    checkFromConfig partialConfig $ \config -> do
      runtime <- newOnDemandRuntime config
      usageOrder <- odsUsageOrder <$> readTVarIO (odrState runtime)
      return $ property $ null usageOrder

prop_newOnDemandRuntimeStartsWithoutTipIfRemoteMissing :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithoutTipIfRemoteMissing partialConfig =
  ioQuickly $
    withTemp $ \tmp -> do
      testWithFileServer (ServerFolder tmp) $ \port -> do
        mbMTip <-
          getTopLevelConfigFilePath
            >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir tmp) port)
            >>= newOnDemandRuntime
            >>= atomically . readOnDemandTip
        return $ mbMTip === Nothing

prop_RemoteTipInfoRoundtripsThroughJSON :: RemoteTipInfo -> Property
prop_RemoteTipInfoRoundtripsThroughJSON tipInfo = decode (encode tipInfo) === Just tipInfo

prop_newOnDemandRuntimeFetchesRemoteTip :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeFetchesRemoteTip partialConfig =
  ioQuickly $ do
    let rawSlotNo = 1234
        rawBlockNo = 567
        tipInfo =
          RemoteTipInfo
            { rtiSlot = rawSlotNo
            , rtiBlockNo = rawBlockNo
            , rtiHashBytes = BS.pack $ replicate 32 0x42
            }
    withTemp $ \remoteDir -> do
      LBS.writeFile (remoteDir </> "tip.json") (encode tipInfo)
      withTemp $ \cacheDir -> do
        testWithFileServer (ServerFolder remoteDir) $ \port -> do
          mbTip <-
            getTopLevelConfigFilePath
              >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir cacheDir) port)
              >>= newOnDemandRuntime
              >>= atomically . readOnDemandTip
          pure $ case mbTip of
            Nothing -> counterexample "Failed to fetch tip" False
            Just observedTip ->
              conjoin
                [ counterexample "Slot number mismatch" $ SlotNo rawSlotNo === odtSlot observedTip
                , counterexample "Block number mismatch" $ BlockNo rawBlockNo === odtBlockNo observedTip
                , counterexample "Hash mismatch" $
                    rtiHashBytes tipInfo === toRawHash (Proxy @StandardBlock) (odtHash observedTip)
                ]

----------------------------- Helper functions, types, and instances -----------------------------
instance Eq ChunkInfo where
  UniformChunkSize cs1 == UniformChunkSize cs2 = cs1 == cs2

instance Eq ChunkSize where
  (==) cs1 cs2 =
    numRegularBlocks cs1 == numRegularBlocks cs2
      && chunkCanContainEBB cs1 == chunkCanContainEBB cs2

instance ToJSON (OnDemandTip StandardBlock) where
  toJSON OnDemandTip{..} =
    object
      [ "slot" .= odtSlot
      , "block_no" .= odtBlockNo
      , "hash" .= Encoding.decodeUtf8 (toRawHash (Proxy @(CardanoBlock StandardCrypto)) odtHash)
      ]

checkFromConfig ::
  PartialOnDemandConfig -> (OnDemandConfig IO StandardBlock HandleIO -> IO Property) -> IO Property
checkFromConfig partialConfig mkProp =
  withTemp $ \tmp -> do
    cfg <- getTopLevelConfigFilePath
    testWithFileServer (ServerFolder $ takeDirectory cfg) $
      mkFullConfig partialConfig (ConfigFile cfg) (TmpDir tmp) >=> mkProp

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "on-demand-runtime-test"

----------------------------- Property aggregation -----------------------------
tests :: TestTree
tests =
  testGroup
    "On-Demand Runtime"
    [ testProperty
        "newOnDemandRuntime contains the given config info"
        prop_newOnDemandRuntimeContainsConfigInfoAsGiven
    , testProperty
        "newOnDemandRuntime starts with empty cached chunks"
        prop_newOnDemandRuntimeStartsWithEmptyCachedChunks
    , testProperty
        "newOnDemandRuntime starts with empty usage order"
        prop_newOnDemandRuntimeStartsWithEmptyUsageOrder
    , testProperty
        "newOnDemandRuntime starts with Nothing when remote tip is missing"
        prop_newOnDemandRuntimeStartsWithoutTipIfRemoteMissing
    , testProperty
        "RemoteTipInfo roundtrips through JSON encoding/decoding"
        prop_RemoteTipInfoRoundtripsThroughJSON
    , testProperty
        "newOnDemandRuntime fetches tip from remote"
        prop_newOnDemandRuntimeFetchesRemoteTip
    ]
