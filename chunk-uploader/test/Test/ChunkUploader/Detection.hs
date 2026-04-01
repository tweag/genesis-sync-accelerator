module Test.ChunkUploader.Detection (tests) where

import ChunkUploader.Detection (scanCompletedChunks)
import ChunkUploader.Types (ChunkNo (..), chunkExtensions, chunkFileName)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "detection-test"

-- | Write non-empty content for all three files of a chunk.
createCompletedChunk :: FilePath -> ChunkNo -> IO ()
createCompletedChunk dir cn =
  mapM_ (\ext -> writeFile (dir </> chunkFileName cn ext) "content") chunkExtensions

-- | Write only the .chunk file, leaving the triplet incomplete.
createIncompleteChunk :: FilePath -> ChunkNo -> IO ()
createIncompleteChunk dir cn =
  writeFile (dir </> chunkFileName cn ".chunk") "content"

-- | Write all three files but leave them empty.
createEmptyChunk :: FilePath -> ChunkNo -> IO ()
createEmptyChunk dir cn =
  mapM_ (\ext -> writeFile (dir </> chunkFileName cn ext) "") chunkExtensions

tests :: TestTree
tests =
  testGroup
    "ChunkUploader.Detection"
    [ testCase "empty directory returns []" $
        withTmp $ \dir -> do
          result <- scanCompletedChunks dir
          result @?= []
    , testCase "only chunk (the tip) is excluded" $
        withTmp $ \dir -> do
          createCompletedChunk dir (ChunkNo 0)
          result <- scanCompletedChunks dir
          result @?= []
    , testCase "completed chunk below the tip is returned" $
        withTmp $ \dir -> do
          createCompletedChunk dir (ChunkNo 0)
          createCompletedChunk dir (ChunkNo 1)
          result <- scanCompletedChunks dir
          result @?= [ChunkNo 0]
    , testCase "chunk with missing files is excluded" $
        withTmp $ \dir -> do
          createIncompleteChunk dir (ChunkNo 0)
          createCompletedChunk dir (ChunkNo 1)
          result <- scanCompletedChunks dir
          result @?= []
    , testCase "chunk with empty files is excluded" $
        withTmp $ \dir -> do
          createEmptyChunk dir (ChunkNo 0)
          createCompletedChunk dir (ChunkNo 1)
          result <- scanCompletedChunks dir
          result @?= []
    , testCase "multiple completed chunks are returned sorted" $
        withTmp $ \dir -> do
          mapM_ (createCompletedChunk dir . ChunkNo) [0, 1, 2, 3]
          result <- scanCompletedChunks dir
          result @?= map ChunkNo [0, 1, 2]
    ]
