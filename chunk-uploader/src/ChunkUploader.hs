{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ChunkUploader
  ( runUploader
  ) where

import Cardano.Slotting.Slot (WithOrigin (..))
import ChunkUploader.Detection (scanCompletedChunks)
import ChunkUploader.S3 (S3Handle, credentialsWork, initS3, uploadChunkTriplet, uploadTipJson)
import ChunkUploader.State
  ( defaultStateFile
  , loadState
  , saveState
  )
import ChunkUploader.Types
  ( ChunkNo
  , TraceUploaderEvent (..)
  , UploaderConfig (..)
  )
import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import GenesisSyncAccelerator.Types (StandardTopLevelConfig)
import GenesisSyncAccelerator.Util (getImmDbTip, getTopLevelConfig)
import System.Exit (exitFailure)
import "contra-tracer" Control.Tracer (Tracer, traceWith)

-- | Maximum number of retry attempts per chunk upload.
maxRetries :: Int
maxRetries = 3

-- | Initial retry delay, in seconds.
initialRetryDelaySecs :: Int
initialRetryDelaySecs = 1

-- | Maximum retry delay, in seconds.
maxRetryDelaySecs :: Int
maxRetryDelaySecs = 30

-- | Delay for a given retry attempt using exponential backoff.
delayForAttempt :: Int -> IO ()
delayForAttempt attempt = threadDelay $ 1_000_000 * min maxRetryDelaySecs (initialRetryDelaySecs * 2 ^ attempt)

-- | Run the main upload loop. This function does not return.
runUploader :: Tracer IO TraceUploaderEvent -> UploaderConfig -> IO ()
runUploader tracer cfg = do
  s3 <- initS3 cfg >>= either (\e -> traceWith tracer (TraceS3InitFailure e) >> exitFailure) pure
  ok <- credentialsWork s3
  unless ok $ do
    traceWith tracer (TraceCredentialValidationFailure "HeadBucket request failed")
    exitFailure
  let stateFile = fromMaybe (defaultStateFile $ ucImmutableDir cfg) (ucStateFile cfg)
  lastUploaded <- loadState stateFile
  traceWith tracer (TraceStateLoaded lastUploaded)
  mlTopLevelCfg <- case ucNodeConfig cfg of
    Nothing -> pure Nothing
    Just configPath -> Just <$> getTopLevelConfig configPath
  loop tracer cfg s3 stateFile lastUploaded mlTopLevelCfg

loop ::
  Tracer IO TraceUploaderEvent ->
  UploaderConfig ->
  S3Handle ->
  FilePath ->
  Maybe ChunkNo ->
  Maybe StandardTopLevelConfig ->
  IO ()
loop tracer cfg s3 stateFile lastUploaded mlTopLevelCfg = do
  traceWith tracer TraceScanStart
  completed <- scanCompletedChunks (ucImmutableDir cfg)
  traceWith tracer (TraceScanComplete completed)
  let newChunks = case lastUploaded of
        Nothing -> completed
        Just n -> filter (> n) completed
  newLast <- uploadChunks tracer s3 cfg stateFile lastUploaded newChunks
  case mlTopLevelCfg of
    Just topLevelCfg
      | newLast /= lastUploaded ->
          uploadTip tracer s3 topLevelCfg (ucImmutableDir cfg)
    _ -> pure ()
  threadDelay (ucPollInterval cfg * 1_000_000)
  loop tracer cfg s3 stateFile newLast mlTopLevelCfg

uploadChunks ::
  Tracer IO TraceUploaderEvent ->
  S3Handle ->
  UploaderConfig ->
  FilePath ->
  Maybe ChunkNo ->
  [ChunkNo] ->
  IO (Maybe ChunkNo)
uploadChunks _ _ _ _ current [] = pure current
uploadChunks tracer s3 cfg stateFile _ (cn : rest) = do
  success <- uploadChunkWithRetry tracer s3 cfg cn 0
  if success
    then do
      saveState stateFile cn
      traceWith tracer (TraceStateSaved cn)
      uploadChunks tracer s3 cfg stateFile (Just cn) rest
    else
      -- Stop uploading on failure; will retry next poll cycle
      pure (Just cn)

uploadChunkWithRetry ::
  Tracer IO TraceUploaderEvent ->
  S3Handle ->
  UploaderConfig ->
  ChunkNo ->
  Int ->
  IO Bool
uploadChunkWithRetry tracer s3 cfg cn attempt = do
  traceWith tracer (TraceUploadStart cn)
  result <- try $ uploadChunkTriplet s3 cn (ucImmutableDir cfg)
  case result of
    Right () -> do
      traceWith tracer (TraceUploadSuccess cn)
      pure True
    Left (e :: SomeException)
      | Just (SomeAsyncException _) <- fromException e -> throwIO e
      | otherwise -> do
          traceWith tracer (TraceUploadFailure cn (show e) (show attempt))
          if attempt < maxRetries
            then do
              delayForAttempt attempt
              traceWith tracer (TraceUploadRetry cn (attempt + 1))
              uploadChunkWithRetry tracer s3 cfg cn (attempt + 1)
            else pure False

uploadTip ::
  Tracer IO TraceUploaderEvent ->
  S3Handle ->
  StandardTopLevelConfig ->
  FilePath ->
  IO ()
uploadTip tracer s3 topLevelCfg immDir = do
  traceWith tracer TraceTipUploadStart
  result <- try $ do
    mTip <- getImmDbTip topLevelCfg immDir
    case mTip of
      Origin -> pure ()
      At tip -> uploadTipJson s3 tip
  case result of
    Right () -> traceWith tracer TraceTipUploadSuccess
    Left (e :: SomeException)
      | Just (SomeAsyncException _) <- fromException e -> throwIO e
      | otherwise -> traceWith tracer (TraceTipUploadFailure (show e))
