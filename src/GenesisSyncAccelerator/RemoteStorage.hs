{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- | HTTP client for downloading ImmutableDB chunks from a CDN.
--
-- This module handles the transport layer for the Genesis Sync Accelerator.
-- It provides functions to fetch the triad of files (@.chunk@, @.primary@, @.secondary@)
-- that constitute an ImmutableDB chunk from a remote HTTP server.
module GenesisSyncAccelerator.RemoteStorage
  ( downloadChunk
  , DownloadFailed (..)
  , FileType (..)
  , RemoteStorageConfig (..)
  , RemoteStorageTracer
  , getFileName
  , toSuffix
  ) where

import Control.Exception (Exception, SomeException, throwIO, try)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import Data.Word (Word64)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import "contra-tracer" Control.Tracer

-- | Configuration for the remote storage client.
data RemoteStorageConfig = RemoteStorageConfig
  { rscSrcUrl :: String
  -- ^ The root URL of the CDN (e.g., "https://cdn.cardano.org/mainnet/immutable").
  , rscDstDir :: FilePath
  -- ^ Local directory where the downloaded chunks should be stored.
  }

-- | Events traced by the Remote Storage client.
data TraceRemoteStorageEvent
  = -- | Starting download of a file.
    TraceDownloadStart String
  | -- | Successfully downloaded a file.
    TraceDownloadSuccess String Word64
  | -- | Failed to download a file with an exception.
    TraceDownloadException String String
  | -- | Failed to download a file with a non-200 HTTP status.
    TraceDownloadError String Int
  deriving (Eq, Show)

type RemoteStorageTracer m = Tracer m TraceRemoteStorageEvent

-- | Exception thrown when a file download fails (HTTP error or non-200 status).
newtype DownloadFailed = DownloadFailed String
  deriving Show

instance Exception DownloadFailed

data FileType = ChunkFile | PrimaryIndexFile | SecondaryIndexFile | EpochFile
  deriving (Eq, Show)

getFileName :: FileType -> ChunkNo -> Text.Text
getFileName fileType (ChunkNo chunk) = Text.justifyRight 5 '0' (Text.pack (show chunk)) <> "." <> toSuffix fileType

toSuffix :: FileType -> Text.Text
toSuffix = \case
  ChunkFile -> "chunk"
  PrimaryIndexFile -> "primary"
  SecondaryIndexFile -> "secondary"
  EpochFile -> "epoch"

-- | Downloads all files associated with a specific chunk index.
--
-- This function fetches the @.chunk@, @.primary@, and @.secondary@ files.
downloadChunk :: RemoteStorageTracer IO -> RemoteStorageConfig -> ChunkNo -> IO ()
downloadChunk tracer cfg chunk = do
  manager <- newManager tlsManagerSettings
  createDirectoryIfMissing True (rscDstDir cfg)
  let fileTypes = [ChunkFile, PrimaryIndexFile, SecondaryIndexFile]
  mapM_ (downloadFile tracer manager cfg chunk) fileTypes

-- | Internal helper to download a single file using the provided HTTP 'Manager'.
downloadFile ::
  RemoteStorageTracer IO -> Manager -> RemoteStorageConfig -> ChunkNo -> FileType -> IO ()
downloadFile tracer manager cfg chunk fileType = do
  let filename = Text.unpack $ getFileName fileType chunk
      localPath = rscDstDir cfg </> filename
  -- Construct request
  request <- parseRequest (rscSrcUrl cfg ++ "/" ++ filename)

  -- Perform the download
  traceWith tracer $ TraceDownloadStart filename
  result <- try (httpLbs request manager) :: IO (Either SomeException (Response LBS.ByteString))

  case result of
    Left ex -> do
      traceWith tracer $ TraceDownloadException filename (show ex)
      throwIO $ DownloadFailed filename
    Right response -> do
      let status = statusCode (responseStatus response)
      if status == 200
        then do
          let body = responseBody response
          LBS.writeFile localPath body
          traceWith tracer $ TraceDownloadSuccess filename (fromIntegral (LBS.length body))
        else do
          traceWith tracer $ TraceDownloadError filename status
          throwIO $ DownloadFailed filename
