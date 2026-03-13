{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}

-- | HTTP client for downloading ImmutableDB chunks from a CDN.
--
-- This module handles the transport layer for the Genesis Sync Accelerator.
-- It provides functions to fetch the triad of files (@.chunk@, @.primary@, @.secondary@)
-- that constitute an ImmutableDB chunk from a remote HTTP server.
module GenesisSyncAccelerator.RemoteStorage
  ( downloadChunk
  , fetchTipInfo
  , newRemoteStorageEnv
  , RemoteStorageConfig (..)
  , RemoteStorageEnv (..)
  , RemoteTipInfo (..)
  , TraceRemoteStorageEvent (..)
  , RemoteStorageTracer
  , TraceDownloadFailure (..)
  , getFileName
  , toSuffix
  , FileType (..)
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Catch (MonadThrow)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, object, withObject, (.:), (.=))
import qualified Data.Bifunctor as Bifunctor
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import GenesisSyncAccelerator.Tracing
  ( RemoteStorageTracer
  , TraceDownloadFailure (..)
  , TraceRemoteStorageEvent (..)
  )
import Network.HTTP.Client hiding (Manager)
import qualified Network.HTTP.Client as HTTP (Manager, newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import "contra-tracer" Control.Tracer

-- | Configuration for the remote storage client.
data RemoteStorageConfig = RemoteStorageConfig
  { rscSrcUrl :: String
  -- ^ The root URL of the CDN (e.g., "https://cdn.cardano.org/mainnet/immutable"), without trailing slash.
  , rscDstDir :: FilePath
  -- ^ Local directory where the downloaded chunks should be stored.
  }
  deriving (Eq, Show)

-- | Smart constructor that creates a shared HTTP 'Manager' for the lifetime of the env.
-- Strips any trailing slashes from the URL.
newRemoteStorageEnv :: String -> FilePath -> IO RemoteStorageEnv
newRemoteStorageEnv url dir =
  (\mgr -> RemoteStorageEnv{rseConfig = cfg, rseManager = mgr})
    <$> HTTP.newManager tlsManagerSettings
 where
  cfg = RemoteStorageConfig{rscSrcUrl = dropTrailingSlashes url, rscDstDir = dir}
  dropTrailingSlashes s
    | not (null s) && last s == '/' = dropTrailingSlashes (init s)
    | otherwise = s

-- | Runtime environment for the remote storage client, pairing a 'RemoteStorageConfig'
-- with a shared HTTP 'Manager'.
data RemoteStorageEnv = RemoteStorageEnv
  { rseConfig :: RemoteStorageConfig
  , rseManager :: HTTP.Manager
  }

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
  RemoteStorageEnv ->
  ChunkNo ->
  IO (Either TraceDownloadFailure [FilePath])
downloadChunk tracer env chunk = do
  createDirectoryIfMissing True $ rscDstDir $ rseConfig env
  let fileTypes = [ChunkFile, PrimaryIndexFile, SecondaryIndexFile]
  sequence <$> mapM (downloadFile tracer env chunk) fileTypes

-- | Internal helper to download a single file using the provided HTTP 'Manager'.
downloadFile ::
  RemoteStorageTracer IO ->
  RemoteStorageEnv ->
  ChunkNo ->
  FileType ->
  IO (Either TraceDownloadFailure FilePath)
downloadFile eventTracer env chunk fileType = do
  let cfg = rseConfig env
      manager = rseManager env
      filename = Text.unpack $ getFileName fileType chunk
      localPath = rscDstDir cfg </> filename
      processResponse r =
        case statusCode (responseStatus r) of
          200 -> do
            let body = responseBody r
            LBS.writeFile localPath body
            traceWith eventTracer $ TraceDownloadSuccess filename (fromIntegral (LBS.length body))
            pure $ Right localPath
          status -> traceFail $ TraceDownloadError filename status
      traceFail f = traceWith (contramap TraceDownloadFailure eventTracer) f >> pure (Left f)
  -- Construct request
  request <- getRequest cfg filename
  -- Perform the download
  traceWith eventTracer $ TraceDownloadStart filename
  (try (httpLbs request manager) :: IO (Either SomeException (Response LBS.ByteString)))
    >>= either (traceFail . TraceDownloadException filename . show) processResponse

getRequest :: MonadThrow m => RemoteStorageConfig -> String -> m Request
getRequest cfg name = parseRequest (rscSrcUrl cfg ++ "/" ++ name)

fetchTipInfo ::
  RemoteStorageTracer IO -> RemoteStorageEnv -> IO (Either TraceDownloadFailure RemoteTipInfo)
fetchTipInfo tracer env = do
  request <- getRequest (rseConfig env) "tip.json"
  let tipUrl = show $ getUri request
      processResponse r =
        case statusCode (responseStatus r) of
          200 -> Bifunctor.first (TraceDownloadException tipUrl) $ eitherDecode (responseBody r)
          status -> Left $ TraceDownloadError tipUrl status
  traceWith tracer $ TraceDownloadStart tipUrl
  result <-
    try (httpLbs request (rseManager env)) :: IO (Either SomeException (Response LBS.ByteString))
  return $ either (Left . TraceDownloadException tipUrl . show) processResponse result

instance FromJSON RemoteTipInfo where
  parseJSON = withObject "RemoteTipInfo" $ \o ->
    RemoteTipInfo
      <$> o .: "slot"
      <*> o .: "block_no"
      <*> ( o .: "hash" >>= \h -> case decodeTipHash h of
              Left err -> fail $ "Failed to decode tip hash: " ++ err
              Right hashBytes -> pure hashBytes
          )

instance ToJSON RemoteTipInfo where
  toJSON RemoteTipInfo{..} =
    object
      [ "slot" .= rtiSlot
      , "block_no" .= rtiBlockNo
      , "hash" .= Text.decodeUtf8 (Base16.encode rtiHashBytes)
      ]

decodeTipHash :: Text.Text -> Either String BS.ByteString
decodeTipHash = Base16.decode . Text.encodeUtf8
