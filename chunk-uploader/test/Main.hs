module Main (main) where

import qualified Test.ChunkUploader.Detection as Detection
import qualified Test.ChunkUploader.S3 as S3
import qualified Test.ChunkUploader.State as State
import qualified Test.ChunkUploader.Types as Types
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "chunk-uploader"
      [ Types.tests
      , Detection.tests
      , State.tests
      , S3.tests
      ]
