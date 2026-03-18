{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.OnDemand.EnsureChunks (tests) where

import Control.Concurrent.Class.MonadSTM.Strict.TVar.Checked (readTVarIO)
import Control.Monad (forM_)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.List as List
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NEL
import qualified Data.Set as Set
import qualified Data.Set.NonEmpty as NES
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import Data.Word (Word16, Word64)
import GHC.Conc (atomically)
import GenesisSyncAccelerator.OnDemand
  ( OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandState (..)
  , ensureChunks
  , newOnDemandRuntime
  )
import GenesisSyncAccelerator.RemoteStorage (toSuffix)
import GenesisSyncAccelerator.Types (MaxCachedChunksCount (..), PrefetchChunksCount (..))
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkInfo (..)
  , ChunkNo (..)
  , ChunkSize (..)
  )
import Ouroboros.Consensus.Util.NormalForm.StrictTVar (writeTVar)
import Paths_genesis_sync_accelerator (getDataFileName)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Orphans ()
import Test.GenesisSyncAccelerator.Types (ConfigFile (..), PartialOnDemandConfig (..), TmpDir (..))
import Test.GenesisSyncAccelerator.Utilities
  ( allFileTypes
  , getCurrentFilenamesForChunk
  , ioQuickly
  , mkFullConfig
  , topLevelConfigFileRelativePath
  , tracerToFile
  )
import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty)

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
        _ <- ensureChunks runtime $ NEL.singleton $ ChunkNo 0
        state0 <- readTVarIO (odrState runtime)
        assertEqual "Cache contains chunk 0" (Set.singleton (ChunkNo 0)) (odsCachedChunks state0)

        -- Request chunk 1
        _ <- ensureChunks runtime $ NEL.singleton $ ChunkNo 1
        state1 <- readTVarIO (odrState runtime)
        assertEqual
          "Cache contains chunks 0 and 1"
          (Set.fromList [ChunkNo 0, ChunkNo 1])
          (odsCachedChunks state1)

        -- Request chunk 2
        _ <- ensureChunks runtime $ NEL.singleton $ ChunkNo 2
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

prop_whenAllRequestedChunksAreCachedEnsureChunksReturnsTrue ::
  PartialOnDemandConfig -> NonEmpty ChunkNo -> PortNo -> Property
prop_whenAllRequestedChunksAreCachedEnsureChunksReturnsTrue partialConfig chunkNumbers port =
  ioQuickly $
    withTemp $ \tmp -> do
      config <-
        getDataFileName topLevelConfigFileRelativePath
          >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir tmp) (fromIntegral port))
      runtime <-
        newOnDemandRuntime
          config{odcMaxCachedChunks = MaxCachedChunksCount (1 + fromIntegral (length chunkNumbers))}
      state <- readTVarIO (odrState runtime)
      atomically $
        writeTVar (odrState runtime) $
          state{odsCachedChunks = Set.fromList (NEL.toList chunkNumbers)}
      cachedChunkNumbers <- odsCachedChunks <$> readTVarIO (odrState runtime)
      assertEqual
        "Precondition: all requested chunks are cached"
        (Set.fromList (NEL.toList chunkNumbers))
        cachedChunkNumbers
      result <- ensureChunks runtime chunkNumbers
      return $ property $ result === True

prop_whenAllRequestedChunksAreCachedEnsureChunksDownloadsNothing ::
  PartialOnDemandConfig -> NonEmpty ChunkNo -> PortNo -> Property
prop_whenAllRequestedChunksAreCachedEnsureChunksDownloadsNothing partialConfig chunkNumbers port =
  ioQuickly $
    withTemp $ \tmp -> do
      let logFile = tmp </> "tmp.log"
      preContents <- Set.fromList <$> listDirectory tmp
      config <-
        getDataFileName topLevelConfigFileRelativePath
          >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir tmp) (fromIntegral port))
      runtime <-
        newOnDemandRuntime
          config
            { odcTracer = tracerToFile logFile
            , odcMaxCachedChunks = MaxCachedChunksCount (1 + fromIntegral (length chunkNumbers))
            }
      state <- readTVarIO (odrState runtime)
      atomically $
        writeTVar (odrState runtime) $
          state{odsCachedChunks = Set.fromList (NEL.toList chunkNumbers)}
      cachedChunkNumbers <- odsCachedChunks <$> readTVarIO (odrState runtime)
      assertEqual
        "Precondition: all requested chunks are cached"
        (Set.fromList (NEL.toList chunkNumbers))
        cachedChunkNumbers
      _ <- ensureChunks runtime chunkNumbers
      postContents <- Set.fromList <$> listDirectory (takeDirectory logFile)
      logLines <- lines . Text.unpack <$> TIO.readFile logFile
      return $
        conjoin
          [ property $ filter isChunkRelatedLine logLines === []
          , postContents === Set.insert (takeFileName logFile) preContents
          ]

prop_whenNoRequestedChunksAreCachedButAllAreAvailableRemotelyEnsureChunksReturnsTrue ::
  PartialOnDemandConfig -> NonEmpty ChunkNo -> Property
prop_whenNoRequestedChunksAreCachedButAllAreAvailableRemotelyEnsureChunksReturnsTrue partialConfig chunkNumbers =
  ioQuickly $
    withTemp $ \remoteDir -> do
      -- Create dummy files for all requested chunks in "remote"
      forM_ (NEL.toList chunkNumbers) $ \n -> forM_ (getCurrentFilenamesForChunk n) (touchFile . (remoteDir </>))
      withTemp $ \cacheDir -> do
        testWithApplication (pure $ staticApp $ defaultFileServerSettings remoteDir) $ \port -> do
          result <-
            getDataFileName topLevelConfigFileRelativePath
              >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir cacheDir) port)
              >>= newOnDemandRuntime
              >>= flip ensureChunks chunkNumbers
          return $ property $ result === True

prop_whenSomeRequestedChunksAreCachedAndTheRestAreAvailableRemotelyEnsureChunksReturnsTrue ::
  Property
prop_whenSomeRequestedChunksAreCachedAndTheRestAreAvailableRemotelyEnsureChunksReturnsTrue =
  forAll genConfigAndSafeNestedChunkSets $ \(partialConfig, remoteChunks, cachedChunks) ->
    ioQuickly $
      withTemp $ \remoteDir -> do
        -- Create dummy files for all requested chunks in "remote"
        forM_ (NES.toList remoteChunks) $ \n -> forM_ (getCurrentFilenamesForChunk n) (touchFile . (remoteDir </>))
        withTemp $ \cacheDir -> do
          testWithApplication (pure $ staticApp $ defaultFileServerSettings remoteDir) $ \port -> do
            runtime <-
              getDataFileName topLevelConfigFileRelativePath
                >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir cacheDir) port)
                >>= newOnDemandRuntime
            state <- readTVarIO (odrState runtime)
            atomically $
              writeTVar (odrState runtime) $
                state{odsCachedChunks = NES.toSet cachedChunks}
            obsCached <- odsCachedChunks <$> readTVarIO (odrState runtime)
            assertEqual
              "Precondition: all chunks predesignated as cached are cached"
              obsCached
              (NES.toSet cachedChunks)
            result <- ensureChunks runtime $ NES.toList remoteChunks
            return $ property $ result === True

prop_whenSomeRequestedChunksAreCachedAndTheRestAreAvailableRemoteEnsureChunksDownloadsOnlyMissing ::
  Property
prop_whenSomeRequestedChunksAreCachedAndTheRestAreAvailableRemoteEnsureChunksDownloadsOnlyMissing =
  forAll genConfigAndSafeNestedChunkSets $ \(partialConfig, remoteChunks, cachedChunks) ->
    ioQuickly $
      withTemp $ \remoteDir -> do
        -- Create dummy files for all requested chunks in "remote"
        forM_ (NES.toList remoteChunks) $ \n -> forM_ (getCurrentFilenamesForChunk n) (touchFile . (remoteDir </>))
        withTemp $ \cacheDir -> do
          preContents <- listDirectory cacheDir
          testWithApplication (pure $ staticApp $ defaultFileServerSettings remoteDir) $ \port -> do
            config <-
              getDataFileName topLevelConfigFileRelativePath
                >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir cacheDir) port)
            runtime <- newOnDemandRuntime config
            state <- readTVarIO (odrState runtime)
            atomically $
              writeTVar (odrState runtime) $
                state{odsCachedChunks = NES.toSet cachedChunks}
            obsCached <- odsCachedChunks <$> readTVarIO (odrState runtime)
            assertEqual
              "Precondition: all chunks predesignated as cached are cached"
              obsCached
              (NES.toSet cachedChunks)
            _ <- ensureChunks runtime $ NES.toList $ NES.union remoteChunks cachedChunks
            postContents <- listDirectory cacheDir
            let obsDiff = List.sort $ filter (`notElem` preContents) postContents
                expDownloadChunks = Set.toList $ NES.difference remoteChunks cachedChunks
                expDiff = List.sort (expDownloadChunks >>= getCurrentFilenamesForChunk)
            return $ property $ obsDiff === expDiff

prop_whenSomeRequestedChunksAreNeitherCachedNorAvailableRemotelyEnsureChunksReturnsFalse :: Property
prop_whenSomeRequestedChunksAreNeitherCachedNorAvailableRemotelyEnsureChunksReturnsFalse =
  forAll genConfigAndSafeNestedChunkSets $ \(partialConfig, chunksSuperset, chunksSubset) ->
    ioProperty $ do
      let (forServer, forCache) = NEL.partition (\(ChunkNo n) -> even n) $ NES.toList chunksSubset
      assertBool
        "Precondition: some requested chunks will be neither cached nor available remotely"
        (not $ Set.null $ NES.difference chunksSubset chunksSuperset)
      withTemp $ \remoteDir -> do
        -- Create dummy files for only the "superset" of requested chunks in "remote"
        forM_ forServer $ \n -> forM_ (getCurrentFilenamesForChunk n) (touchFile . (remoteDir </>))
        withTemp $ \cacheDir -> do
          testWithApplication (pure $ staticApp $ defaultFileServerSettings remoteDir) $ \port -> do
            config <-
              getDataFileName topLevelConfigFileRelativePath
                >>= (\f -> mkFullConfig partialConfig (ConfigFile f) (TmpDir cacheDir) port)
            runtime <- newOnDemandRuntime config
            state <- readTVarIO (odrState runtime)
            atomically $
              writeTVar (odrState runtime) $
                state{odsCachedChunks = Set.fromList forCache}
            allRemoteAvailable <-
              and
                <$> mapM
                  (doesFileExist . (remoteDir </>))
                  (forServer >>= getCurrentFilenamesForChunk)
            assertBool
              "Precondition: all chunks predesignated as remotely available are indeed available"
              allRemoteAvailable
            obsCache <- odsCachedChunks <$> readTVarIO (odrState runtime)
            assertEqual
              "Precondition: all chunks predesignated as cached are cached"
              obsCache
              (Set.fromList forCache)
            result <- ensureChunks runtime $ NES.toList chunksSuperset
            return $ property $ result === False

type PortNo = Word16

instance Arbitrary (NonEmpty ChunkNo) where
  arbitrary = do
    h <- arbitrary
    t <- choose (0, 3) >>= flip vectorOf arbitrary -- Limit chunk count just for test speed.
    return $ h :| t

-- Generate a partial config and two chunk number sets, one containing the other.
genConfigAndSafeNestedChunkSets :: Gen (PartialOnDemandConfig, NES.NESet ChunkNo, NES.NESet ChunkNo)
genConfigAndSafeNestedChunkSets = do
  partialConfig <- arbitrary
  (remoteChunks, cachedChunks) <- genNestedChunkSets
  pure
    ( partialConfig
        { podcMaxCachedChunks =
            MaxCachedChunksCount $ fromIntegral $ 1 + NES.size cachedChunks + NES.size remoteChunks
        }
    , remoteChunks
    , cachedChunks
    )

genNestedChunkSets :: Gen (NES.NESet ChunkNo, NES.NESet ChunkNo)
genNestedChunkSets = do
  n <- choose (2, maxSupersetSize - 1)
  (rawSuper, rest) <- splitAt n <$> shuffle chunks
  let super = NES.unsafeFromSet $ Set.fromList rawSuper
  sub <- (\k -> NES.unsafeFromSet $ Set.fromList $ take k rest) <$> choose (1, n - 1)
  return (super, sub)
 where
  maxSupersetSize = 5
  chunks = map ChunkNo [0 :: Word64 .. (fromIntegral (maxSupersetSize - 1))]

isChunkRelatedLine :: String -> Bool
isChunkRelatedLine line = List.isInfixOf "TraceDownload" line && any (`List.isInfixOf` line) suffixes
 where
  suffixes = map (Text.unpack . toSuffix) allFileTypes

touchFile :: FilePath -> IO ()
touchFile f = writeFile f ""

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "ensure-chunks-test"

tests :: TestTree
tests =
  testGroup
    "Tests of ensureChunks"
    [ testCase
        "ensureChunks maintains maxCachedChunks through LRU policy"
        test_ensureChunksLRU
    , testProperty
        "When all requested chunks are cached, ensureChunks returns True"
        prop_whenAllRequestedChunksAreCachedEnsureChunksReturnsTrue
    , testProperty
        "When all requested chunks are cached, ensureChunks downloads nothing"
        prop_whenAllRequestedChunksAreCachedEnsureChunksDownloadsNothing
    , testProperty
        "When no requested chunks are cached but all are available remotely, ensureChunks returns True"
        prop_whenNoRequestedChunksAreCachedButAllAreAvailableRemotelyEnsureChunksReturnsTrue
    , testProperty
        "When some requested chunks are cached and the rest are available remotely, ensureChunks returns True"
        prop_whenSomeRequestedChunksAreCachedAndTheRestAreAvailableRemotelyEnsureChunksReturnsTrue
    , testProperty
        "When some requested chunks are cached and the rest are available remotely, ensureChunks downloads only the missing chunks"
        prop_whenSomeRequestedChunksAreCachedAndTheRestAreAvailableRemoteEnsureChunksDownloadsOnlyMissing
    , testProperty
        "When some requested chunks are neither cached nor available remotely, ensureChunks returns False"
        prop_whenSomeRequestedChunksAreNeitherCachedNorAvailableRemotelyEnsureChunksReturnsFalse
    ]
