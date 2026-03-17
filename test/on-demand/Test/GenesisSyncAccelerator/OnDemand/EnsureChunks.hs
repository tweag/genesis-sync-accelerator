{-# LANGUAGE ExplicitForAll #-}

module Test.GenesisSyncAccelerator.OnDemand.EnsureChunks (tests) where

import Control.Concurrent.Class.MonadSTM.Strict.TVar.Checked (readTVarIO)
import Control.Monad (forM_)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.Set as Set
import GenesisSyncAccelerator.OnDemand
  ( OnDemandRuntime (..)
  , OnDemandState (..)
  , ensureChunks
  , newOnDemandRuntime
  )
import GenesisSyncAccelerator.Types (MaxCachedChunksCount (..), PrefetchChunksCount (..))
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkInfo (..)
  , ChunkNo (..)
  , ChunkSize (..)
  )
import Paths_genesis_sync_accelerator (getDataFileName)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Types (ConfigFile (..), PartialOnDemandConfig (..), TmpDir (..))
import Test.GenesisSyncAccelerator.Utilities
  ( getCurrentFilenamesForChunk
  , mkFullConfig
  , topLevelConfigFileRelativePath
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

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
                , podcMaxCachedChunks = MaxCachedChunksCount 2 -- This is what's under test.
                , podcPrefetchAhead = PrefetchChunksCount 0
                }
        configFile <- getDataFileName topLevelConfigFileRelativePath
        config <- mkFullConfig partialConfig (ConfigFile configFile) (TmpDir cacheDir) port
        runtime <- newOnDemandRuntime config

        -- Request chunk 0
        _ <- ensureChunks runtime [ChunkNo 0]
        state0 <- readTVarIO (odrState runtime)
        assertEqual "Cache contains chunk 0" (Set.singleton (ChunkNo 0)) (odsCachedChunks state0)

        -- Request chunk 1
        _ <- ensureChunks runtime [ChunkNo 1]
        state1 <- readTVarIO (odrState runtime)
        assertEqual
          "Cache contains chunks 0 and 1"
          (Set.fromList [ChunkNo 0, ChunkNo 1])
          (odsCachedChunks state1)

        -- Request chunk 2
        _ <- ensureChunks runtime [ChunkNo 2]
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

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "ensure-chunks-test"

tests :: TestTree
tests =
  testGroup
    "Tests of ensureChunks"
    [ testCase
        "ensureChunks maintains maxCachedChunks through LRU policy"
        test_ensureChunksLRU
    ]
