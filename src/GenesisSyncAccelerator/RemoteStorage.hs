{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

-- | HTTP client for downloading ImmutableDB chunks from a CDN.
--
-- This module handles the transport layer for the Genesis Sync Accelerator.
-- It provides functions to fetch the triad of files (@.chunk@, @.primary@, @.secondary@)
-- that constitute an ImmutableDB chunk from a remote HTTP server.
module GenesisSyncAccelerator.RemoteStorage
  ( downloadChunk
  , fetchTipInfo
  , newRemoteStorageEnv
  , newRemoteStorageEnvWithConfig
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

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad.Catch (MonadThrow)
import Control.Monad.IO.Class (MonadIO, liftIO)
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

data RemoteStorageConfig = RemoteStorageConfig
  { rscSrcUrl :: String
  -- ^ The root URL of the CDN (e.g., "https://cdn.cardano.org/mainnet/immutable"), without trailing slash.
  , rscDstDir :: FilePath
  -- ^ Local directory where the downloaded chunks should be stored.
  , rscMaxRetries :: Int
  -- ^ Maximum number of retries for transient failures.
  , rscBaseDelay :: Int
  -- ^ Base delay in microseconds for exponential backoff.
  }
  deriving (Eq, Show)

-- | Smart constructor that creates a shared HTTP 'Manager' for the lifetime of the env.
-- Sets default retry configuration: 5 retries, 100ms base delay.
newRemoteStorageEnv :: String -> FilePath -> IO RemoteStorageEnv
newRemoteStorageEnv url dir =
  newRemoteStorageEnvWithConfig
    RemoteStorageConfig
      { rscSrcUrl = url
      , rscDstDir = dir
      , rscMaxRetries = 5
      , rscBaseDelay = 100000
      }

-- | Create a 'RemoteStorageEnv' from an existing 'RemoteStorageConfig'.
newRemoteStorageEnvWithConfig :: RemoteStorageConfig -> IO RemoteStorageEnv
newRemoteStorageEnvWithConfig cfg =
  (\mgr -> RemoteStorageEnv{rseConfig = cfg, rseManager = mgr})
    <$> HTTP.newManager tlsManagerSettings

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
  results <- mapM (downloadFile tracer env chunk) fileTypes
  return $ sequence results

-- | Internal helper to download a single file using the provided HTTP 'Manager'.
downloadFile ::
  RemoteStorageTracer IO ->
  RemoteStorageEnv ->
  ChunkNo ->
  FileType ->
  IO (Either TraceDownloadFailure FilePath)
downloadFile eventTracer env chunk fileType =
  let filename = Text.unpack $ getFileName fileType chunk
      localPath = rscDstDir (rseConfig env) </> filename
      traceSuccess url response = TraceDownloadSuccess url (fromIntegral (LBS.length (responseBody response)))
      procBody body = LBS.writeFile localPath body >> pure (Right localPath)
   in tryFileRequest TraceDownloadStart procBody traceSuccess eventTracer env filename

getRequest :: MonadThrow m => RemoteStorageConfig -> String -> m Request
getRequest cfg name = parseRequest (rscSrcUrl cfg ++ "/" ++ name)

fetchTipInfo ::
  RemoteStorageTracer IO -> RemoteStorageEnv -> IO (Either TraceDownloadFailure RemoteTipInfo)
fetchTipInfo tracer env =
  tryFileRequest
    TraceTipFetchStart
    (pure <$> eitherDecode)
    (\url _ -> TraceTipFetchSuccess url)
    tracer
    env
    "tip.json"

-- | Retry an action with exponential backoff if it fails with a transient error.
withRetry ::
  MonadIO m =>
  RemoteStorageTracer m ->
  RemoteStorageConfig ->
  String ->
  m (Either TraceDownloadFailure a) ->
  m (Either TraceDownloadFailure a)
withRetry tr cfg url action = go 0
 where
  maxRetries = rscMaxRetries cfg
  baseDelay = rscBaseDelay cfg
  go n = do
    res <- action
    case res of
      Left f@(TraceDownloadError _ status) | status >= 500 -> retry n f
      Left f@(TraceDownloadException _ _) -> retry n f
      _ -> pure res

  retry n lastRes
    | n >= maxRetries = pure (Left lastRes)
    | otherwise = do
        let delay = baseDelay * (2 ^ n)
        traceWith tr $ TraceDownloadRetry url (n + 1) delay
        liftIO $ threadDelay delay
        go (n + 1)

tryFileRequest ::
  forall m result.
  (MonadIO m, MonadThrow m) =>
  (String -> TraceRemoteStorageEvent) ->
  (LBS.ByteString -> IO (Either String result)) ->
  (String -> Response LBS.ByteString -> TraceRemoteStorageEvent) ->
  RemoteStorageTracer m ->
  RemoteStorageEnv ->
  String ->
  m (Either TraceDownloadFailure result)
tryFileRequest traceStart procBody traceSuccess tr env filename = do
  req <- getRequest (rseConfig env) filename
  withRetry tr (rseConfig env) (getUrl req) $ do
    traceWith tr $ traceStart $ getUrl req
    outcome <-
      liftIO $
        (try (httpLbs req (rseManager env)) :: IO (Either SomeException (Response LBS.ByteString)))
          >>= either (pure . Left . TraceDownloadException (getUrl req) . show) (processResponse req)
    case outcome of
      Left f -> do
        traceWith tr (TraceDownloadFailure f)
        pure (Left f)
      Right (response, result) -> do
        traceWith tr (traceSuccess (getUrl req) response)
        pure (Right result)
 where
  getUrl = show . getUri
  processResponse req r = case statusCode (responseStatus r) of
    200 -> Bifunctor.bimap (TraceDownloadException (getUrl req)) (r,) <$> procBody (responseBody r)
    status -> pure $ Left $ TraceDownloadError (getUrl req) status

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
