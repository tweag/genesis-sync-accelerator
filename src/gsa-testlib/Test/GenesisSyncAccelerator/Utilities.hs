{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}

-- | Utilities for test suites
module Test.GenesisSyncAccelerator.Utilities
  ( allFileTypes
  , currentFileTypes
  , genSeveralChunkNumbers
  , getAllFilenamesForChunk
  , blockChunk
  , getCurrentFilenamesForChunk
  , getLocalUrl
  , getTopLevelConfigFilePath
  , groupBlocksByChunk
  , ioQuickly
  , mkFullConfig
  , testWithFileServer
  , tracerToFile
  ) where

import qualified Data.Map as Map
import qualified Data.Text as Text
import GenesisSyncAccelerator.OnDemand (OnDemandConfig (..))
import GenesisSyncAccelerator.RemoteStorage (FileType (..), RemoteStorageConfig (..), getFileName)
import GenesisSyncAccelerator.Types (RetryCount (..), StandardBlock)
import GenesisSyncAccelerator.Util (fpToHasFS, getTopLevelConfig)
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp (Port, testWithApplication)
import Ouroboros.Consensus.Block (HasHeader)
import Ouroboros.Consensus.Block.Abstract (blockSlot)
import Ouroboros.Consensus.Config (configCodec)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks (ChunkInfo)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Layout as ChunkLayout
import Paths_genesis_sync_accelerator (getDataFileName)
import System.FS.IO (HandleIO)
import System.FilePath ((</>))
import Test.GenesisSyncAccelerator.Types
  ( ConfigFile (..)
  , PartialOnDemandConfig (..)
  , ServerFolder (..)
  , TmpDir (..)
  )
import Test.QuickCheck
import "contra-tracer" Control.Tracer (Tracer (..), nullTracer)

-- | An exhaustive list of all file types possibly associated with a chunk.
allFileTypes :: [FileType]
allFileTypes = EpochFile : currentFileTypes

-- | A list of file types that the accelerator is currently expected to download for a chunk.
currentFileTypes :: [FileType]
currentFileTypes = [ChunkFile, PrimaryIndexFile, SecondaryIndexFile]

-- | Generate 2-5 chunk numbers, in the range 1-10, without duplicates.
genSeveralChunkNumbers :: Gen [ChunkNo]
genSeveralChunkNumbers = do
  n <- choose (2, 5)
  raws <- shuffle [1 .. 10]
  return $ map ChunkNo $ take n raws

-- | Get the name of each file possibly associated with a chunk.
getAllFilenamesForChunk :: ChunkNo -> [String]
getAllFilenamesForChunk cn = getFilenamesForChunk cn allFileTypes

-- | Get the chunk number for the given block
blockChunk :: HasHeader blk => ChunkInfo -> blk -> ChunkNo
blockChunk ci = ChunkLayout.chunkIndexOfSlot ci . blockSlot

-- | List the name of each file currently expected to be associated with a chunk.
getCurrentFilenamesForChunk :: ChunkNo -> [String]
getCurrentFilenamesForChunk cn = getFilenamesForChunk cn currentFileTypes

-- | For the given chunk, for the given file types, the the expected file name.
getFilenamesForChunk :: ChunkNo -> [FileType] -> [String]
getFilenamesForChunk cn = map (\ft -> Text.unpack $ getFileName ft cn)

getLocalUrl :: Int -> String
getLocalUrl port = "http://localhost:" ++ show port

getTopLevelConfigFilePath :: IO FilePath
getTopLevelConfigFilePath = getDataFileName $ "test" </> "data" </> "config" </> "config.json"

groupBlocksByChunk :: HasHeader blk => ChunkInfo -> [blk] -> Map.Map ChunkNo [blk]
groupBlocksByChunk ci = foldr (\b acc -> Map.insertWith (\_ old -> b : old) (blockChunk ci b) [b] acc) Map.empty

ioQuickN :: forall prop. Testable prop => Int -> IO prop -> Property
ioQuickN n = withMaxSuccess n . ioProperty

ioQuickly :: forall prop. Testable prop => IO prop -> Property
ioQuickly = ioQuickN 5

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
      { odcRemote =
          RemoteStorageConfig
            { rscSrcUrl = getLocalUrl port
            , rscDstDir = tmpdir
            , rscMaxRetries = RetryCount 0 -- Disable retries in tests by default
            , rscBaseDelay = 0
            }
      , odcTracer = nullTracer
      , odcChunkInfo = podcChunkInfo
      , odcHasFS = fpToHasFS tmpdir
      , odcCodecConfig = codecConfig
      , odcCheckIntegrity = const podcIntegrityConstant
      , odcMaxCachedChunks = podcMaxCachedChunks
      , odcPrefetchAhead = podcPrefetchAhead
      }

testWithFileServer :: ServerFolder -> (Port -> IO a) -> IO a
testWithFileServer (ServerFolder dataDir) = testWithApplication (pure $ staticApp $ defaultFileServerSettings dataDir)

-- Trace values of given type to given file by appending the 'show' representation with a newline.
tracerToFile :: Show a => FilePath -> Tracer IO a
tracerToFile f = Tracer (\a -> appendFile f (show a ++ "\n"))
