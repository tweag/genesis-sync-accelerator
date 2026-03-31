{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ChunkUploader.S3
  ( S3Handle
  , initS3
  , credentialsWork
  , uploadChunkFile
  , uploadChunkTriplet
  , uploadTipJson
  , chunkExistsOnS3
  , parseEndpoint
  ) where

import qualified Amazonka
import qualified Amazonka.S3 as S3
import ChunkUploader.Types
  ( ChunkNo
  , UploaderConfig (..)
  , chunkExtensions
  , chunkFileName
  )
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import GenesisSyncAccelerator.RemoteStorage (RemoteTipInfo)
import Network.HTTP.Client (parseRequest)
import qualified Network.HTTP.Client as HTTP
import System.FilePath ((</>))

-- | Handle for S3 operations.
data S3Handle = S3Handle
  { s3Env :: !Amazonka.Env
  , s3Bucket :: !S3.BucketName
  , s3Prefix :: !Text
  }

-- | Initialize the S3 handle from uploader config.
-- Discovers credentials from environment variables (AWS_ACCESS_KEY_ID,
-- AWS_SECRET_ACCESS_KEY) which works for both AWS and R2.
initS3 :: UploaderConfig -> IO (Either Text S3Handle)
initS3 cfg = do
  env0 <- Amazonka.newEnv Amazonka.discover
  let region = Amazonka.Region' (ucS3Region cfg)
      env1 = env0{Amazonka.region = region}
  pure $ do
    env2 <- case ucS3Endpoint cfg of
      Nothing -> Right env1
      Just ep -> do
        (useTLS, host, port) <- parseEndpoint ep
        let svc =
              Amazonka.setEndpoint
                useTLS
                host
                port
                S3.defaultService
            -- AWS S3 buckets rely on wildcard DNS resolution (<bucket-name>.s3.<region>.amazonaws.com),
            -- which doesn't work with custom endpoints (R2, MinIO). Use path-style addressing instead.
            svc' = svc{Amazonka.s3AddressingStyle = Amazonka.S3AddressingStylePath}
         in Right $ Amazonka.configureService svc' env1
    Right
      S3Handle
        { s3Env = env2
        , s3Bucket = S3.BucketName (ucS3Bucket cfg)
        , s3Prefix = ucS3Prefix cfg
        }

-- | Try an IO action, returning 'True' on success and 'False' on
-- synchronous exceptions. Async exceptions are re-thrown.
trySync :: IO a -> IO Bool
trySync action = do
  result <- try action
  case result of
    Right _ -> pure True
    Left (e :: SomeException)
      | Just (SomeAsyncException _) <- fromException e -> throwIO e
      | otherwise -> pure False

-- | Check S3 credentials by performing a HeadBucket request.
credentialsWork :: S3Handle -> IO Bool
credentialsWork h =
  trySync $ Amazonka.runResourceT (Amazonka.send (s3Env h) (S3.newHeadBucket (s3Bucket h)))

-- | Upload a single chunk file to S3.
uploadChunkFile :: S3Handle -> ChunkNo -> String -> FilePath -> IO ()
uploadChunkFile h cn ext localDir = do
  let fileName = chunkFileName cn ext
      localPath = localDir </> fileName
      key = S3.ObjectKey (s3Prefix h <> T.pack fileName)
  body <- Amazonka.chunkedFile Amazonka.defaultChunkSize localPath
  let req = S3.newPutObject (s3Bucket h) key body
  Amazonka.runResourceT $ do
    _ <- Amazonka.send (s3Env h) req
    pure ()

-- | Upload all three files (.chunk, .primary, .secondary) for a chunk.
uploadChunkTriplet :: S3Handle -> ChunkNo -> FilePath -> IO ()
uploadChunkTriplet h cn localDir =
  mapM_ (\ext -> uploadChunkFile h cn ext localDir) chunkExtensions

-- | Parse an endpoint URL into (useTLS, host, port).
parseEndpoint :: Text -> Either Text (Bool, BS.ByteString, Int)
parseEndpoint url =
  case parseRequest (T.unpack url) of
    Nothing ->
      Left $ "Invalid endpoint URL: " <> url
    Just req
      | let path = HTTP.path req
      , path /= "/" && path /= "" ->
          Left $
            "Endpoint URL must not contain a path (Amazonka's setEndpoint does not support path prefixes), got: "
              <> url
      | otherwise ->
          Right
            ( HTTP.secure req
            , HTTP.host req
            , HTTP.port req
            )

-- | Serialise a 'RemoteTipInfo' to JSON and upload it as @tip.json@ under the
-- configured prefix.
uploadTipJson :: S3Handle -> RemoteTipInfo -> IO ()
uploadTipJson h info = do
  let key = S3.ObjectKey (s3Prefix h <> "tip.json")
      body = Amazonka.toBody (encode info)
      req = S3.newPutObject (s3Bucket h) key body
  Amazonka.runResourceT $ do
    _ <- Amazonka.send (s3Env h) req
    pure ()

-- | Check if a chunk's .chunk file already exists on S3.
-- Used for startup reconciliation.
chunkExistsOnS3 :: S3Handle -> ChunkNo -> IO Bool
chunkExistsOnS3 h cn =
  let ext = case chunkExtensions of
        (e : _) -> e
        [] -> error "chunkExtensions must be non-empty"
      key = S3.ObjectKey (s3Prefix h <> T.pack (chunkFileName cn ext))
   in trySync $ Amazonka.runResourceT (Amazonka.send (s3Env h) (S3.newHeadObject (s3Bucket h) key))
