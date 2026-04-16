{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import Data.Void
import Data.Yaml (decodeFileThrow)
import GenesisSyncAccelerator.Config
  ( PartialConfig (..)
  , RTSFrequency (..)
  , ResolvedOpts (..)
  , defaultConfig
  , showAddr
  )
import qualified GenesisSyncAccelerator.Config as Config
import qualified GenesisSyncAccelerator.Diffusion as Diffusion
import GenesisSyncAccelerator.Parsers (parseAddr)
import qualified GenesisSyncAccelerator.RemoteStorage as RemoteStorage
import GenesisSyncAccelerator.Tracing (Tracers (..), startResourceTracer)
import GenesisSyncAccelerator.Types (HostAddr)
import GenesisSyncAccelerator.Util (getTopLevelConfig)
import Main.Utf8 (withStdTerminalHandles)
import qualified Network.Socket as Socket
import Options.Applicative
import System.Directory (XdgDirectory (XdgCache), getXdgDirectory)
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)
import "contra-tracer" Control.Tracer (showTracing, stdoutTracer, traceWith)

main :: IO ()
main = withStdTerminalHandles $ do
  hSetBuffering stdout LineBuffering
  cryptoInit
  (gsaConfigPath, cliOpts) <- execParser optsParser
  fileOpts <- case gsaConfigPath of
    Nothing -> pure mempty
    Just path -> decodeFileThrow path
  xdgCache <- getXdgDirectory XdgCache "genesis-sync-accelerator"
  let defaults = defaultConfig{pcCacheDir = Just xdgCache}
  opts <- case Config.resolveOpts (cliOpts <> fileOpts <> defaults) of
    Left err -> do
      hPutStrLn stderr $ "Error: " ++ err
      exitFailure
    Right o -> pure o
  let sockAddr = resolveAddr opts
  let tracers =
        Tracers
          { blockFetchMessageTracer = showTracing stdoutTracer
          , blockFetchEventTracer = showTracing stdoutTracer
          , chainSyncMessageTracer = showTracing stdoutTracer
          , chainSyncEventTracer = showTracing stdoutTracer
          , remoteStorageTracer = showTracing stdoutTracer
          , handshakeTracer = showTracing stdoutTracer
          , bearerTracer = showTracing stdoutTracer
          }
  pInfoConfig <- getTopLevelConfig (resolvedNodeConfig opts)
  traceWith stdoutTracer $
    "Running ImmDB server at " ++ printHost (resolvedAddr opts, resolvedPort opts)
  startResourceTracer stdoutTracer (unRTSFrequency (resolvedRtsFrequency opts))
  let remoteCfg = RemoteStorage.RemoteStorageConfig (resolvedSrcUrl opts) (resolvedCacheDir opts)
  absurd
    <$> Diffusion.run
      remoteCfg
      (resolvedMaxCachedChunks opts)
      (resolvedPrefetchAhead opts)
      (resolvedTipRefreshInterval opts)
      tracers
      sockAddr
      pInfoConfig

resolveAddr :: ResolvedOpts -> Socket.SockAddr
resolveAddr opts = Socket.SockAddrInet (resolvedPort opts) hostAddr
 where
  hostAddr = Socket.tupleToHostAddress (resolvedAddr opts)

printHost :: (HostAddr, Socket.PortNumber) -> String
printHost (addr, port) = showAddr addr ++ ":" ++ show port

optsParser :: ParserInfo (Maybe FilePath, PartialConfig)
optsParser =
  info (helper <*> parse) $ fullDesc <> progDesc desc
 where
  desc = "Serve ImmutableDB chunks via ChainSync and BlockFetch"

  parse = do
    gsaConfigPath <-
      optional $
        strOption $
          mconcat
            [ long "gsa-config"
            , help "Path to GSA YAML configuration file (can be overridden via CLI arguments)"
            , metavar "PATH"
            ]
    pcAddr <-
      optional $
        option (eitherReader parseAddr) $
          mconcat
            [ long "addr"
            , help "Address to serve at (default: 127.0.0.1)"
            ]
    pcPort <-
      optional $
        option auto $
          mconcat
            [ long "port"
            , help "Port to serve on (default: 3001)"
            ]
    pcNodeConfig <-
      optional $
        strOption $
          mconcat
            [ long "node-config"
            , help "Path to Cardano node config file"
            , metavar "PATH"
            ]
    pcRtsFrequency <-
      optional $
        option auto $
          mconcat
            [ long "rts-frequency"
            , help "Frequency (in milliseconds) to poll GHC RTS statistics (default: 1000)"
            ]
    pcCacheDir <-
      optional $
        strOption $
          mconcat
            [ long "cache-dir"
            , help
                "Local cache directory for downloaded ImmutableDB chunks (default: $XDG_CACHE_HOME/genesis-sync-accelerator)"
            , metavar "PATH"
            ]
    pcSrcUrl <-
      optional $
        strOption $
          mconcat
            [ long "rs-src-url"
            , help
                "URL to a CDN serving ImmutableDB chunks (e.g. https://example.com/chain)"
            , metavar "URL"
            ]
    pcMaxCachedChunks <-
      optional $
        option auto $
          mconcat
            [ long "max-cached-chunks"
            , help "Maximum number of chunks to keep in cache (default: 10)"
            ]
    pcPrefetchAhead <-
      optional $
        option auto $
          mconcat
            [ long "prefetch-ahead"
            , help "Number of chunks to prefetch ahead of current position (default: 3)"
            ]
    pcTipRefreshInterval <-
      optional $
        option auto $
          mconcat
            [ long "tip-refresh-interval"
            , help "How often to re-fetch the tip from the CDN, in seconds (default: 600)"
            ]
    pure
      ( gsaConfigPath
      , PartialConfig
          { pcAddr
          , pcPort
          , pcNodeConfig
          , pcRtsFrequency
          , pcCacheDir
          , pcSrcUrl
          , pcMaxCachedChunks
          , pcPrefetchAhead
          , pcTipRefreshInterval
          }
      )
