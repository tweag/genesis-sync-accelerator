{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.OnDemandRuntime (tests) where

import Control.Concurrent.Class.MonadSTM.Strict.TVar.Checked (readTVarIO)
import Control.Monad (forM_)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (ToJSON (..), decode, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Proxy (Proxy (..))
import qualified Data.Set as Set
import qualified Data.Text.Encoding as Encoding
import GHC.Conc (atomically)
import GenesisSyncAccelerator.OnDemand
  ( OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandState (..)
  , OnDemandTip (..)
  , ensureChunks
  , newOnDemandRuntime
  , readOnDemandTip
  )
import GenesisSyncAccelerator.RemoteStorage (RemoteStorageConfig (..), RemoteTipInfo (..))
import GenesisSyncAccelerator.Types (StandardBlock)
import GenesisSyncAccelerator.Util (fpToHasFS, getTopLevelConfig)
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.Block
  ( BlockNo (..)
  , ConvertRawHash (fromRawHash, toRawHash)
  , SlotNo (..)
  )
import Ouroboros.Consensus.Cardano.Block (CardanoBlock, CardanoEras, StandardCrypto)
import Ouroboros.Consensus.Config (configCodec)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (OneEraHash)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkInfo (..)
  , ChunkNo (..)
  , ChunkSize (..)
  )
import Paths_genesis_sync_accelerator (getDataFileName)
import System.Directory (doesFileExist)
import System.FS.IO (HandleIO)
import System.FilePath (takeDirectory, (</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Utilities (getCurrentFilenamesForChunk)
import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)
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

prop_newOnDemandRuntimeStartsWithoutTipIfRemoteMissing :: PartialOnDemandConfig -> Property
prop_newOnDemandRuntimeStartsWithoutTipIfRemoteMissing partialConfig =
  ioProperty $
    withTemp $ \tmp -> do
      testWithApplication (pure $ staticApp $ defaultFileServerSettings tmp) $
        \port -> do
          config <- mkFullConfig partialConfig (ConfigFile topLevelConfigFileRelativePath) (TmpDir tmp) port
          mbTip <- newOnDemandRuntime config >>= atomically . readOnDemandTip
          return $ mbTip === Nothing

prop_RemoteTipInfoRoundtripsThroughJSON :: RemoteTipInfo -> Property
prop_RemoteTipInfoRoundtripsThroughJSON tipInfo = decode (encode tipInfo) === Just tipInfo

test_ensureChunksLRU :: IO ()
test_ensureChunksLRU = do
  withTemp $ \remoteDir -> do
    -- 1. Create dummy files for 3 chunks in "remote"
    forM_ [0, 1, 2] $ \n -> do
      forM_ (getCurrentFilenamesForChunk (ChunkNo n)) $ \fn ->
        writeFile (remoteDir </> fn) "dummy"

    withTemp $ \cacheDir -> do
      testWithApplication (pure $ staticApp $ defaultFileServerSettings remoteDir) $ \port -> do
        let partialConfig =
              PartialOnDemandConfig
                { podcChunkInfo = UniformChunkSize (ChunkSize False 10)
                , podcIntegrityConstant = True
                , podcMaxCachedChunks = 2
                }
        configFile <- getDataFileName topLevelConfigFileRelativePath
        config <- mkFullConfig partialConfig (ConfigFile configFile) (TmpDir cacheDir) port
        runtime <- newOnDemandRuntime config

        -- Request chunk 0
        _ <- ensureChunks (odrConfig runtime) (odrState runtime) [ChunkNo 0]
        state0 <- readTVarIO (odrState runtime)
        assertEqual "Cache contains chunk 0" (Set.singleton (ChunkNo 0)) (odsCachedChunks state0)

        -- Request chunk 1
        _ <- ensureChunks (odrConfig runtime) (odrState runtime) [ChunkNo 1]
        state1 <- readTVarIO (odrState runtime)
        assertEqual
          "Cache contains chunks 0 and 1"
          (Set.fromList [ChunkNo 0, ChunkNo 1])
          (odsCachedChunks state1)

        -- Request chunk 2
        _ <- ensureChunks (odrConfig runtime) (odrState runtime) [ChunkNo 2]
        state2 <- readTVarIO (odrState runtime)
        assertEqual
          "Cache contains chunks 1 and 2"
          (Set.fromList [ChunkNo 1, ChunkNo 2])
          (odsCachedChunks state2)
        assertEqual "Chunk 0 evicted from state" False (ChunkNo 0 `Set.member` odsCachedChunks state2)

        -- Verify files deleted from disk
        forM_ (getCurrentFilenamesForChunk (ChunkNo 0)) $ \fn -> do
          exists <- doesFileExist (cacheDir </> fn)
          assertEqual ("Chunk 0 file " ++ fn ++ " deleted") False exists

        -- Verify files present for chunks 1 and 2
        forM_ [1, 2] $ \n ->
          forM_ (getCurrentFilenamesForChunk (ChunkNo n)) $ \fn -> do
            exists <- doesFileExist (cacheDir </> fn)
            assertEqual ("Chunk " ++ show n ++ " file " ++ fn ++ " present") True exists

test_newOnDemandRuntimeFetchesRemoteTip :: IO ()
test_newOnDemandRuntimeFetchesRemoteTip = do
  let tipInfo =
        RemoteTipInfo
          { rtiSlot = 1234
          , rtiBlockNo = 567
          , rtiHashBytes = BS.pack $ replicate 32 0x42
          }
  withTemp $ \remoteDir -> do
    LBS.writeFile (remoteDir </> "tip.json") (encode tipInfo)

    withTemp $ \cacheDir -> do
      testWithApplication (pure $ staticApp $ defaultFileServerSettings remoteDir) $ \port -> do
        let partialConfig =
              PartialOnDemandConfig
                { podcChunkInfo = UniformChunkSize (ChunkSize False 10)
                , podcIntegrityConstant = True
                , podcMaxCachedChunks = 2
                }
        configFile <- getDataFileName topLevelConfigFileRelativePath
        config <- mkFullConfig partialConfig (ConfigFile configFile) (TmpDir cacheDir) port
        mbTip <- newOnDemandRuntime config >>= atomically . readOnDemandTip
        case mbTip of
          Nothing -> assertFailure "Failed to fetch tip"
          Just observedTip -> do
            assertEqual "Slot matches" (SlotNo 1234) (odtSlot observedTip)
            assertEqual "BlockNo matches" (BlockNo 567) (odtBlockNo observedTip)
            assertEqual
              "Hash matches"
              (rtiHashBytes tipInfo)
              (toRawHash (Proxy @StandardBlock) (odtHash observedTip))

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
        tmpdir = TmpDir tmp
    testWithApplication (pure $ staticApp $ defaultFileServerSettings dataDir) $
      \port -> do
        config <- mkFullConfig partialConfig (ConfigFile configFile) tmpdir port
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
        "newOnDemandRuntime starts with empty usage order"
        prop_newOnDemandRuntimeStartsWithEmptyUsageOrder
    , testProperty
        "newOnDemandRuntime starts with Nothing when remote tip is missing"
        prop_newOnDemandRuntimeStartsWithoutTipIfRemoteMissing
    , testProperty
        "RemoteTipInfo roundtrips through JSON encoding/decoding"
        prop_RemoteTipInfoRoundtripsThroughJSON
    , testCase
        "ensureChunks maintains maxCachedChunks through LRU policy"
        test_ensureChunksLRU
    , testCase
        "newOnDemandRuntime fetches tip from remote"
        test_newOnDemandRuntimeFetchesRemoteTip
    ]
