module Test.ChunkUploader.Types (tests) where

import ChunkUploader.Types (ChunkNo (..), chunkFileName)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ChunkUploader.Types"
    [ testCase "zero-pads single-digit chunk numbers" $
        chunkFileName (ChunkNo 0) ".chunk" @?= "00000.chunk"
    , testCase "zero-pads two-digit chunk numbers" $
        chunkFileName (ChunkNo 42) ".chunk" @?= "00042.chunk"
    , testCase "does not pad five-digit chunk numbers" $
        chunkFileName (ChunkNo 12345) ".chunk" @?= "12345.chunk"
    , testCase "appends .primary extension" $
        chunkFileName (ChunkNo 1) ".primary" @?= "00001.primary"
    , testCase "appends .secondary extension" $
        chunkFileName (ChunkNo 1) ".secondary" @?= "00001.secondary"
    ]
