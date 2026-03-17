{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import ChunkUploader (runUploader)
import ChunkUploader.Types
  ( TraceUploaderEvent
  , UploaderConfig (..)
  )
import qualified Data.Text as T
import Main.Utf8 (withStdTerminalHandles)
import Options.Applicative
import System.IO (BufferMode (..), hSetBuffering, stdout)
import "contra-tracer" Control.Tracer (Tracer, showTracing, stdoutTracer)

main :: IO ()
main = withStdTerminalHandles $ do
  hSetBuffering stdout LineBuffering
  cfg <- execParser optsInfo
  let tracer :: Tracer IO TraceUploaderEvent
      tracer = showTracing stdoutTracer
  runUploader tracer cfg

optsInfo :: ParserInfo UploaderConfig
optsInfo =
  info
    (optsParser <**> helper)
    ( fullDesc
        <> progDesc "Upload completed ImmutableDB chunk files to S3-compatible storage"
        <> header "chunk-uploader - CDN chunk uploader for Cardano ImmutableDB"
    )

optsParser :: Parser UploaderConfig
optsParser = do
  ucImmutableDir <-
    strOption
      ( long "immutable-dir"
          <> metavar "PATH"
          <> help "Path to the ImmutableDB immutable/ directory to watch"
      )
  ucS3Bucket <-
    T.pack
      <$> strOption
        ( long "s3-bucket"
            <> metavar "BUCKET"
            <> help "S3 bucket name"
        )
  ucS3Prefix <-
    T.pack
      <$> strOption
        ( long "s3-prefix"
            <> metavar "PREFIX"
            <> value "immutable/"
            <> showDefault
            <> help "Key prefix for uploaded objects"
        )
  ucS3Endpoint <-
    optional $
      T.pack
        <$> strOption
          ( long "s3-endpoint"
              <> metavar "URL"
              <> help
                "Custom S3 endpoint URL as scheme://host[:port] (for Cloudflare R2, MinIO, etc.). Path components are not supported because Amazonka's setEndpoint only accepts host and port."
          )
  ucS3Region <-
    T.pack
      <$> strOption
        ( long "s3-region"
            <> metavar "REGION"
            <> value "us-east-1"
            <> showDefault
            <> help "AWS region"
        )
  ucPollInterval <-
    option
      auto
      ( long "poll-interval"
          <> metavar "SECONDS"
          <> value 10
          <> showDefault
          <> help "How often to check for new chunks"
      )
  ucStateFile <-
    optional $
      strOption
        ( long "state-file"
            <> metavar "PATH"
            <> help "Upload progress state file (default: <immutable-dir>/.chunk-uploader-state)"
        )
  pure
    UploaderConfig
      { ucImmutableDir
      , ucS3Bucket
      , ucS3Prefix
      , ucS3Endpoint
      , ucS3Region
      , ucPollInterval
      , ucStateFile
      }
