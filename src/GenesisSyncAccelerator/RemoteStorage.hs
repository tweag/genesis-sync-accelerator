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
  , fetchTipInfo
  , RemoteStorageConfig (..)
  , RemoteTipInfo (..)
  , TraceRemoteStorageEvent (..)
  , RemoteStorageTracer
  , TraceDownloadFailure (..)
  , getFileName
  , toSuffix
  , FileType (..)
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
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
  | -- | Failed to download a file.
    TraceDownloadFailure TraceDownloadFailure
  | -- | Starting download of tip metadata.
    TraceTipFetchStart !String
  deriving (Eq, Show)

-- | Download failure reasons.
data TraceDownloadFailure
  = -- | Exception during download.
    TraceDownloadException String String
  | -- | Non-200 HTTP status.
    TraceDownloadError String Int
  deriving (Eq, Show)

type RemoteStorageTracer m = Tracer m TraceRemoteStorageEvent

data RemoteTipInfo = RemoteTipInfo
  { rtiSlot :: Word64
  , rtiBlockNo :: Word64
  , rtiHashBytes :: BS.ByteString
  }
  deriving (Eq, Show)

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
downloadChunk ::
  RemoteStorageTracer IO ->
  RemoteStorageConfig ->
  ChunkNo ->
  IO (Either TraceDownloadFailure [FilePath])
downloadChunk tracer cfg chunk = do
  manager <- newManager tlsManagerSettings
  createDirectoryIfMissing True (rscDstDir cfg)
  let fileTypes = [ChunkFile, PrimaryIndexFile, SecondaryIndexFile]
  sequence <$> mapM (downloadFile tracer manager cfg chunk) fileTypes

-- | Internal helper to download a single file using the provided HTTP 'Manager'.
downloadFile ::
  RemoteStorageTracer IO ->
  Manager ->
  RemoteStorageConfig ->
  ChunkNo ->
  FileType ->
  IO (Either TraceDownloadFailure FilePath)
downloadFile eventTracer manager cfg chunk fileType = do
  let filename = Text.unpack $ getFileName fileType chunk
      localPath = rscDstDir cfg </> filename
      failureTracer = contramap TraceDownloadFailure eventTracer
      processResponse r =
        case statusCode (responseStatus r) of
          200 -> do
            let body = responseBody r
            LBS.writeFile localPath body
            traceWith eventTracer $ TraceDownloadSuccess filename (fromIntegral (LBS.length body))
            pure $ Right localPath
          status ->
            let e = TraceDownloadError filename status
             in traceWith failureTracer e >> pure (Left e)
      traceEx :: SomeException -> IO (Either TraceDownloadFailure FilePath)
      traceEx ex =
        let e = TraceDownloadException filename $ show ex
         in traceWith failureTracer e >> pure (Left e)
  -- Construct request
  request <- parseRequest (rscSrcUrl cfg ++ "/" ++ filename)
  -- Perform the download
  traceWith eventTracer $ TraceDownloadStart filename
  try (httpLbs request manager) >>= either traceEx processResponse

fetchTipInfo :: RemoteStorageTracer IO -> RemoteStorageConfig -> IO (Maybe RemoteTipInfo)
fetchTipInfo tracer cfg = do
  manager <- newManager tlsManagerSettings
  let tipUrl = rscSrcUrl cfg ++ "/tip.json"
  traceWith tracer $ TraceDownloadStart tipUrl
  request <- parseRequest tipUrl
  result <- try (httpLbs request manager) :: IO (Either SomeException (Response LBS.ByteString))
  case result of
    Left ex -> do
      traceWith tracer . TraceDownloadFailure $ TraceDownloadException tipUrl (show ex)
      pure Nothing
    Right response -> do
      let status = statusCode (responseStatus response)
      if status /= 200
        then do
          traceWith tracer . TraceDownloadFailure $ TraceDownloadError tipUrl status
          pure Nothing
        else case eitherDecode (responseBody response) of
          Left err -> do
            traceWith tracer . TraceDownloadFailure $ TraceDownloadException tipUrl err
            pure Nothing
          Right tipJson ->
            case decodeTipHash (rtHash tipJson) of
              Left err -> do
                traceWith tracer . TraceDownloadFailure $ TraceDownloadException tipUrl err
                pure Nothing
              Right hashBytes ->
                pure $
                  Just
                    RemoteTipInfo
                      { rtiSlot = rtSlot tipJson
                      , rtiBlockNo = rtBlockNo tipJson
                      , rtiHashBytes = hashBytes
                      }

data RemoteTipJson = RemoteTipJson
  { rtSlot :: Word64
  , rtBlockNo :: Word64
  , rtHash :: Text.Text
  }

instance FromJSON RemoteTipJson where
  parseJSON = withObject "RemoteTipJson" $ \o ->
    RemoteTipJson
      <$> o .: "slot"
      <*> o .: "block_no"
      <*> o .: "hash"

decodeTipHash :: Text.Text -> Either String BS.ByteString
decodeTipHash hashText =
  case Base16.decode (Text.encodeUtf8 hashText) of
    Left err -> Left err
    Right bytes -> Right bytes
