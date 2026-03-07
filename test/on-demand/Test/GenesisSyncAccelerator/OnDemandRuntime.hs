{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.OnDemandRuntime (tests) where

import Control.Concurrent.Class.MonadSTM.Strict.TVar.Checked (readTVarIO)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (ToJSON (..), decode, encode, object, (.=))
import qualified Data.ByteString as BS
import Data.Proxy (Proxy (..))
import qualified Data.Text.Encoding as Encoding
import GHC.Conc (atomically)
import GenesisSyncAccelerator.OnDemand
  ( OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandState (..)
  , OnDemandTip (..)
  , dummyTip
  , newOnDemandRuntime
  , readOnDemandTip
  )
import GenesisSyncAccelerator.RemoteStorage (RemoteStorageConfig (..), RemoteTipInfo (..))
import GenesisSyncAccelerator.Types (StandardBlock)
import GenesisSyncAccelerator.Util (fpToHasFS, getTopLevelConfig)
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.Block (ConvertRawHash (fromRawHash, toRawHash))
import Ouroboros.Consensus.Cardano.Block (CardanoBlock, CardanoEras, StandardCrypto)
import Ouroboros.Consensus.Config (configCodec)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (OneEraHash)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkInfo (..), ChunkSize (..))
import Paths_genesis_sync_accelerator (getDataFileName)
import System.Directory (copyFile, listDirectory)
import System.FS.IO (HandleIO)
import System.FilePath (takeDirectory, (</>))
import qualified System.IO.Temp as Temp
import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import "contra-tracer" Control.Tracer (nullTracer)

----------------------------- Generators and properties -----------------------------
instance Arbitrary ChunkInfo where
  arbitrary = do UniformChunkSize <$> arbitrary

instance Arbitrary ChunkSize where
  arbitrary = do
    n <- choose (1, 100)
    p <- arbitrary
    return $ ChunkSize{numRegularBlocks = n, chunkCanContainEBB = p}

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
  ioProperty $
    checkFromConfig partialConfig $ \original -> do
      recovered <- odrConfig <$> newOnDemandRuntime original
      return $
        conjoin
          [ odcChunkInfo recovered === podcChunkInfo
          , odcMaxCachedChunks recovered === podcMaxCachedChunks
          , odcRemote recovered === odcRemote original
          ]

prop_newOnDemandRuntimeStartsWithEmptyCachedChunks :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithEmptyCachedChunks partialConfig =
  ioProperty $
    checkFromConfig partialConfig $ \config -> do
      runtime <- newOnDemandRuntime config
      chunks <- odsCachedChunks <$> readTVarIO (odrState runtime)
      return $ property $ null chunks

prop_newOnDemandRuntimeStartsWithEmptyUsageOrder :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithEmptyUsageOrder partialConfig =
  ioProperty $
    checkFromConfig partialConfig $ \config -> do
      runtime <- newOnDemandRuntime config
      usageOrder <- odsUsageOrder <$> readTVarIO (odrState runtime)
      return $ property $ null usageOrder

prop_newOnDemandRuntimeStartsWithDummyTip :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithDummyTip partialConfig =
  ioProperty $
    withTemp $ \tmp -> do
      dataDir <- takeDirectory <$> getDataFileName topLevelConfigFileRelativePath
      listDirectory dataDir >>= mapM_ (\fn -> copyFile (dataDir </> fn) (tmp </> fn))
      testWithApplication (pure $ staticApp $ defaultFileServerSettings tmp) $
        \port -> do
          config <- mkFullConfig partialConfig (ConfigFile $ tmp </> topLevelConfigFileName) (TmpDir tmp) port
          mbTip <- newOnDemandRuntime config >>= atomically . readOnDemandTip
          case mbTip of
            Nothing -> return $ counterexample "Failed to fetch tip info" False
            Just observedTip -> return $ observedTip === dummyTip

prop_RemoteTipInfoRoundtripsThroughJSON :: RemoteTipInfo -> Property
prop_RemoteTipInfoRoundtripsThroughJSON tipInfo = decode (encode tipInfo) === Just tipInfo

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

data PartialOnDemandConfig = PartialOnDemandConfig
  { podcChunkInfo :: ChunkInfo
  , podcIntegrityConstant :: Bool
  , podcMaxCachedChunks :: Int
  }
  deriving Show

newtype ConfigFile = ConfigFile {unConfigFile :: FilePath} deriving Show

newtype TmpDir = TmpDir {unTmpDir :: FilePath} deriving Show

checkFromConfig ::
  PartialOnDemandConfig -> (OnDemandConfig IO StandardBlock HandleIO -> IO Property) -> IO Property
checkFromConfig partialConfig mkProp =
  withTemp $ \tmp -> do
    configFile <- getDataFileName topLevelConfigFileRelativePath
    let dataDir = takeDirectory configFile
    testWithApplication (pure $ staticApp $ defaultFileServerSettings dataDir) $
      \port -> do
        config <- mkFullConfig partialConfig (ConfigFile configFile) (TmpDir tmp) port
        mkProp config

topLevelConfigFileName :: String
topLevelConfigFileName = "config.json"

topLevelConfigFileRelativePath :: FilePath
topLevelConfigFileRelativePath = "test" </> "data" </> "config" </> topLevelConfigFileName

mkFullConfig ::
  PartialOnDemandConfig ->
  ConfigFile ->
  TmpDir ->
  Int ->
  IO (OnDemandConfig IO StandardBlock HandleIO)
mkFullConfig PartialOnDemandConfig{..} (ConfigFile configFile) (TmpDir tmpdir) port = do
  codecConfig <- configCodec <$> getTopLevelConfig configFile
  return $
    OnDemandConfig
      { odcRemote = mkRemoteStorageConfig tmpdir port
      , odcTracer = nullTracer
      , odcChunkInfo = podcChunkInfo
      , odcHasFS = fpToHasFS tmpdir
      , odcCodecConfig = codecConfig
      , odcCheckIntegrity = const podcIntegrityConstant
      , odcMaxCachedChunks = podcMaxCachedChunks
      }

instance Arbitrary PartialOnDemandConfig where
  arbitrary = do
    chunkInfo <- arbitrary
    integrity <- arbitrary
    maxChunks <- choose (1, 100)
    return
      PartialOnDemandConfig
        { podcChunkInfo = chunkInfo
        , podcIntegrityConstant = integrity
        , podcMaxCachedChunks = maxChunks
        }

mkRemoteStorageConfig :: FilePath -> Int -> RemoteStorageConfig
mkRemoteStorageConfig tmpdir port =
  RemoteStorageConfig
    { rscSrcUrl = "http://localhost:" ++ show port
    , rscDstDir = tmpdir
    }

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "on-demand-test"

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
        "newOnDemandRuntime starts with empty usageorder"
        prop_newOnDemandRuntimeStartsWithEmptyUsageOrder
    , testProperty
        "newOnDemandRuntime starts with dummy tip info"
        prop_newOnDemandRuntimeStartsWithDummyTip
    , testProperty
        "RemoteTipInfo roundtrips through JSON encoding/decoding"
        prop_RemoteTipInfoRoundtripsThroughJSON
    ]
