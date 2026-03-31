module Test.ChunkUploader.State (tests) where

import ChunkUploader.State (defaultStateFile, loadState, saveState)
import ChunkUploader.Types (ChunkNo (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "state-test"

tests :: TestTree
tests =
  testGroup
    "ChunkUploader.State"
    [ testCase "loadState returns Nothing for missing file" $
        withTmp $ \dir -> do
          result <- loadState (dir </> "nonexistent")
          result @?= Nothing
    , testCase "loadState returns Nothing for garbage content" $
        withTmp $ \dir -> do
          let fp = dir </> "state"
          writeFile fp "not a number\n"
          result <- loadState fp
          result @?= Nothing
    , testCase "saveState then loadState round-trips" $
        withTmp $ \dir -> do
          let fp = dir </> "state"
          saveState fp (ChunkNo 42)
          result <- loadState fp
          result @?= Just (ChunkNo 42)
    , testCase "saveState overwrites previous value" $
        withTmp $ \dir -> do
          let fp = dir </> "state"
          saveState fp (ChunkNo 1)
          saveState fp (ChunkNo 99)
          result <- loadState fp
          result @?= Just (ChunkNo 99)
    , testCase "defaultStateFile appends correct filename" $
        defaultStateFile "/some/immutable/dir" @?= "/some/immutable/dir/.chunk-uploader-state"
    ]
