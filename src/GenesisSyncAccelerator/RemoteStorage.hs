{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE LambdaCase #-}

-- | HTTP client for downloading ImmutableDB chunks from a CDN.
--
-- This module handles the transport layer for the Genesis Sync Accelerator.
-- It provides functions to fetch the triad of files (@.chunk@, @.primary@, @.secondary@)
-- that constitute an ImmutableDB chunk from a remote HTTP server.
module GenesisSyncAccelerator.RemoteStorage
  ( downloadChunk
  , RemoteStorageConfig (..)
  , TraceRemoteStorageEvent (..)
  , RemoteStorageTracer
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import Data.Word (Word64)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
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
    TraceRemoteStorageDownloadStart !String
  | -- | Successfully downloaded a file.
    TraceRemoteStorageDownloadSuccess !String !Word64
  | -- | Failed to download a file with an exception.
    TraceRemoteStorageDownloadException !String !String
  | -- | Failed to download a file with a non-200 HTTP status.
    TraceRemoteStorageDownloadError !String !Int
  deriving (Eq, Show)

type RemoteStorageTracer m = Tracer m TraceRemoteStorageEvent

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
-- If a file already exists locally, the download is skipped.
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
  exists <- doesFileExist localPath
  unless exists $ do
    -- Construct request
    request <- parseRequest (rscSrcUrl cfg ++ "/" ++ filename)

    -- Perform the download
    traceWith tracer $ TraceRemoteStorageDownloadStart filename
    result <- try (httpLbs request manager) :: IO (Either SomeException (Response LBS.ByteString))

    case result of
      Left ex -> traceWith tracer $ TraceRemoteStorageDownloadException filename (show ex)
      Right response -> do
        let status = statusCode (responseStatus response)
        if status == 200
          then do
            let body = responseBody response
            LBS.writeFile localPath body
            traceWith tracer $ TraceRemoteStorageDownloadSuccess filename (fromIntegral (LBS.length body))
          else traceWith tracer $ TraceRemoteStorageDownloadError filename status
