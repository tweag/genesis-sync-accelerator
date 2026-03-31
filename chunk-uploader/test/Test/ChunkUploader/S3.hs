{-# LANGUAGE OverloadedStrings #-}

module Test.ChunkUploader.S3 (tests) where

import ChunkUploader.S3 (parseEndpoint)
import Data.Either (isLeft)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ChunkUploader.S3"
    [ testCase "HTTP URL parses host, port, and TLS=False" $
        parseEndpoint "http://localhost:9000" @?= Right (False, "localhost", 9000)
    , testCase "HTTPS URL uses port 443 and TLS=True" $
        parseEndpoint "https://r2.cloudflarestorage.com" @?= Right (True, "r2.cloudflarestorage.com", 443)
    , testCase "URL with path component is rejected" $
        assertBool "expected Left" (isLeft (parseEndpoint "http://localhost:9000/bucket"))
    , testCase "unparseable URL is rejected" $
        assertBool "expected Left" (isLeft (parseEndpoint "://garbage"))
    ]
