{-# LANGUAGE OverloadedStrings #-}

module Test.GenesisSyncAccelerator.Download.Retry (tests) where

import Control.Concurrent.MVar
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import GenesisSyncAccelerator.RemoteStorage
  ( RemoteStorageConfig (..)
  , downloadChunk
  , newRemoteStorageEnvWithConfig
  )
import Network.HTTP.Types (status200, status503)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Utilities (getLocalUrl, tracerToFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

tests :: TestTree
tests =
  testGroup
    "Download Retry Logic"
    [ testCase "downloadChunk retries on 503 and eventually succeeds" testRetrySuccess
    , testCase "downloadChunk eventually fails after max retries" testRetryFailure
    ]

-- | A WAI app that fails with 503 for the first N requests, then succeeds.
mkRetryApp :: MVar Int -> Int -> Application
mkRetryApp counter maxFailures _req respond = do
  n <- modifyMVar counter (\i -> pure (i + 1, i))
  if n < maxFailures
    then respond $ responseLBS status503 [("Content-Type", "text/plain")] "Transient Error"
    else respond $ responseLBS status200 [("Content-Type", "text/plain")] "Success Data"

testRetrySuccess :: IO ()
testRetrySuccess = Temp.withSystemTempDirectory "retry-test-success" $ \tmp -> do
  let cacheDir = tmp </> "cache"
      logFile = tmp </> "retry.log"
      tracer = tracerToFile logFile
      maxFailures = 2
  createDirectoryIfMissing True cacheDir
  counter <- newMVar 0
  testWithApplication (pure $ mkRetryApp counter maxFailures) $ \port -> do
    let cfg =
          RemoteStorageConfig
            { rscSrcUrl = getLocalUrl port
            , rscDstDir = cacheDir
            , rscMaxRetries = 3
            , rscBaseDelay = 1000 -- 1ms for fast tests
            }
    env <- newRemoteStorageEnvWithConfig cfg
    res <- downloadChunk tracer env (ChunkNo 1)

    case res of
      Left err -> fail $ "Expected success after retries, but got: " ++ show err
      Right _ -> do
        logContent <- TIO.readFile logFile
        let retryLines = filter (Text.isInfixOf "TraceDownloadRetry") (Text.lines logContent)
        assertBool "Should have logged retry attempts" (length retryLines >= maxFailures)

testRetryFailure :: IO ()
testRetryFailure = Temp.withSystemTempDirectory "retry-test-failure" $ \tmp -> do
  let cacheDir = tmp </> "cache"
      logFile = tmp </> "retry-fail.log"
      tracer = tracerToFile logFile
      maxRetries = 2
  createDirectoryIfMissing True cacheDir

  -- Use a fixed response that always fails
  let app _req respond = respond $ responseLBS status503 [("Content-Type", "text/plain")] "Transient Error"

  testWithApplication (pure app) $ \port -> do
    let cfg =
          RemoteStorageConfig
            { rscSrcUrl = getLocalUrl port
            , rscDstDir = cacheDir
            , rscMaxRetries = maxRetries
            , rscBaseDelay = 1000
            }
    env <- newRemoteStorageEnvWithConfig cfg
    res <- downloadChunk tracer env (ChunkNo 1)

    case res of
      Right _ -> fail "Expected download to fail after max retries"
      Left _ -> do
        logContent <- TIO.readFile logFile
        let retryLines = filter (Text.isInfixOf "TraceDownloadRetry") (Text.lines logContent)
        -- Since downloadChunk downloads 3 files and our app fails EVERY request,
        -- each of the 3 files will be retried maxRetries times.
        let totalRetries = maxRetries * 3
        assertBool
          ( "Expected exactly "
              ++ show totalRetries
              ++ " retries, but got "
              ++ show (length retryLines)
              ++ ". Log:\n"
              ++ Text.unpack logContent
          )
          (length retryLines == totalRetries)
