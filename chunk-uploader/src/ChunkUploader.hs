{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ChunkUploader
  ( runUploader
  ) where

import ChunkUploader.Detection (scanCompletedChunks)
import ChunkUploader.S3 (S3Handle, initS3, uploadChunkFile)
import ChunkUploader.State
  ( defaultStateFile
  , loadState
  , saveState
  )
import ChunkUploader.Types
  ( ChunkNo
  , TraceUploaderEvent (..)
  , UploaderConfig (..)
  , chunkExtensions
  )
import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Data.Maybe (fromMaybe)
import "contra-tracer" Control.Tracer (Tracer, traceWith)

-- | Maximum number of retry attempts per chunk upload.
maxRetries :: Int
maxRetries = 3

-- | Base delay for exponential backoff, in microseconds (1 second).
baseBackoffMicros :: Int
baseBackoffMicros = 1_000_000

-- | Maximum backoff delay, in microseconds (30 seconds).
maxBackoffMicros :: Int
maxBackoffMicros = 30_000_000

-- | Run the main upload loop. This function does not return.
runUploader :: Tracer IO TraceUploaderEvent -> UploaderConfig -> IO ()
runUploader tracer cfg = do
  s3 <- initS3 cfg
  let stateFile = fromMaybe (defaultStateFile $ ucImmutableDir cfg) (ucStateFile cfg)
  lastUploaded <- loadState stateFile
  traceWith tracer (TraceStateLoaded lastUploaded)
  loop tracer cfg s3 stateFile lastUploaded

loop ::
  Tracer IO TraceUploaderEvent ->
  UploaderConfig ->
  S3Handle ->
  FilePath ->
  Maybe ChunkNo ->
  IO ()
loop tracer cfg s3 stateFile lastUploaded = do
  traceWith tracer TraceScanStart
  completed <- scanCompletedChunks (ucImmutableDir cfg)
  traceWith tracer (TraceScanComplete completed)
  let newChunks = case lastUploaded of
        Nothing -> completed
        Just n -> filter (> n) completed
  newLast <- uploadChunks tracer s3 cfg stateFile lastUploaded newChunks
  threadDelay (ucPollInterval cfg * 1_000_000)
  loop tracer cfg s3 stateFile newLast

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
  result <- try $ mapM_ (\ext -> uploadOneFile tracer s3 cn ext (ucImmutableDir cfg)) chunkExtensions
  case result of
    Right () -> pure True
    Left (e :: SomeException)
      | Just (SomeAsyncException _) <- fromException e -> throwIO e
      | otherwise -> do
          traceWith tracer (TraceUploadFailure cn (show e) (show attempt))
          if attempt < maxRetries
            then do
              traceWith tracer (TraceUploadRetry cn (attempt + 1))
              -- Exponential backoff: 1s, 2s, 4s. Max 30s.
              threadDelay (min maxBackoffMicros (baseBackoffMicros * (2 ^ attempt)))
              uploadChunkWithRetry tracer s3 cfg cn (attempt + 1)
            else pure False

uploadOneFile ::
  Tracer IO TraceUploaderEvent ->
  S3Handle ->
  ChunkNo ->
  String ->
  FilePath ->
  IO ()
uploadOneFile tracer s3 cn ext localDir = do
  traceWith tracer (TraceUploadStart cn ext)
  uploadChunkFile s3 cn ext localDir
  traceWith tracer (TraceUploadSuccess cn ext)
