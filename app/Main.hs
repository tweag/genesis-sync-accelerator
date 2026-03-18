{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import Data.List (intercalate)
import Data.Void
import qualified GenesisSyncAccelerator.Diffusion as Diffusion
import GenesisSyncAccelerator.Parsers (parseAddr)
import qualified GenesisSyncAccelerator.RemoteStorage as RemoteStorage
import GenesisSyncAccelerator.Tracing (Tracers (..), startResourceTracer)
import GenesisSyncAccelerator.Types (HostAddr, MaxCachedChunksCount (..), PrefetchChunksCount (..))
import GenesisSyncAccelerator.Util (getTopLevelConfig)
import Main.Utf8 (withStdTerminalHandles)
import qualified Network.Socket as Socket
import Options.Applicative
import System.Directory (XdgDirectory (XdgCache), getXdgDirectory)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import "contra-tracer" Control.Tracer (showTracing, stdoutTracer, traceWith)

main :: IO ()
main = withStdTerminalHandles $ do
  hSetBuffering stdout LineBuffering
  cryptoInit
  Opts
    { addr
    , port
    , configFile
    , rtsFrequency
    , remoteStorageCacheDir
    , remoteStorageSrcUrl
    , maxCachedChunks
    , prefetchAhead
    } <-
    execParser optsParser
  let sockAddr = Socket.SockAddrInet port hostAddr
       where
        hostAddr = Socket.tupleToHostAddress addr
      tracers =
        Tracers
          { blockFetchMessageTracer = showTracing stdoutTracer
          , blockFetchEventTracer = showTracing stdoutTracer
          , chainSyncMessageTracer = showTracing stdoutTracer
          , chainSyncEventTracer = showTracing stdoutTracer
          , remoteStorageTracer = showTracing stdoutTracer
          }
  cacheDir <- maybe (getXdgDirectory XdgCache "genesis-sync-accelerator") pure remoteStorageCacheDir
  pInfoConfig <- getTopLevelConfig configFile
  traceWith stdoutTracer $ "Running ImmDB server at " ++ printHost (addr, port)
  startResourceTracer stdoutTracer (unRTSFrequency rtsFrequency)
  let remoteCfg = RemoteStorage.RemoteStorageConfig remoteStorageSrcUrl cacheDir
  absurd
    <$> Diffusion.run
      remoteCfg
      maxCachedChunks
      prefetchAhead
      tracers
      sockAddr
      pInfoConfig

newtype RTSFrequency = RTSFrequency {unRTSFrequency :: Int}

-- | Command-line options for the Genesis Sync Accelerator.
data Opts = Opts
  { addr :: HostAddr
  -- ^ IP address to bind to.
  , port :: Socket.PortNumber
  -- ^ TCP port to listen on.
  , configFile :: FilePath
  -- ^ Path to the node configuration file.
  , rtsFrequency :: RTSFrequency
  -- ^ Frequency for tracing RTS statistics.
  , remoteStorageCacheDir :: Maybe FilePath
  -- ^ Location of Sync Accelerator cache. 'Nothing' means use the XDG default ($XDG_CACHE_HOME/genesis-sync-accelerator), or $HOME/.cache/genesis-sync-accelerator if $XDG_CACHE_HOME is not set or empty.
  , remoteStorageSrcUrl :: String
  -- ^ CDN URL for the Genesis Sync Accelerator.
  , maxCachedChunks :: MaxCachedChunksCount
  -- ^ Maximum number of chunks to keep in cache.
  , prefetchAhead :: PrefetchChunksCount
  -- ^ Number of chunks to prefetch ahead of current position.
  }

printHost :: (HostAddr, Socket.PortNumber) -> String
printHost ((a, b, c, d), port) = intercalate "." subs ++ ":" ++ show port
 where
  subs = map show [a, b, c, d]

optsParser :: ParserInfo Opts
optsParser =
  info (helper <*> parse) $ fullDesc <> progDesc desc
 where
  desc = "Serve ImmutableDB chunks via ChainSync and BlockFetch"

  parse = do
    addr <-
      option (eitherReader parseAddr) $
        mconcat
          [ long "addr"
          , help "Address to serve at"
          , value (127, 0, 0, 1)
          , showDefault
          ]
    port <-
      option auto $
        mconcat
          [ long "port"
          , help "Port to serve on"
          , value 3001
          , showDefault
          ]
    configFile <-
      strOption $
        mconcat
          [ long "config"
          , help "Path to config file, in the same format as for the node or db-analyser"
          , metavar "PATH"
          ]
    rtsFrequency <-
      RTSFrequency
        <$> option
          auto
          ( mconcat
              [ long "rts-frequency"
              , help "Frequency (in milliseconds) to poll GHC RTS statistics"
              , value 1000
              , showDefault
              ]
          )
    remoteStorageCacheDir <-
      optional $
        strOption $
          mconcat
            [ long "cache-dir"
            , help
                "Local cache directory for downloaded ImmutableDB chunks (default: $XDG_CACHE_HOME/genesis-sync-accelerator, or $HOME/.cache/genesis-sync-accelerator)"
            , metavar "PATH"
            ]
    remoteStorageSrcUrl <-
      strOption $
        mconcat
          [ long "rs-src-url"
          , help
              "URL to a CDN serving ImmutableDB chunks (e.g. https://example.com/chain)"
          , metavar "URL"
          ]
    maxCachedChunks <-
      MaxCachedChunksCount
        <$> option
          auto
          ( mconcat
              [ long "max-cached-chunks"
              , help "Maximum number of chunks to keep in cache"
              , value 10
              , showDefault
              ]
          )
    prefetchAhead <-
      PrefetchChunksCount
        <$> option
          auto
          ( mconcat
              [ long "prefetch-ahead"
              , help "Number of chunks to prefetch ahead of current position"
              , value 3
              , showDefault
              ]
          )
    pure
      Opts
        { addr
        , port
        , configFile
        , rtsFrequency
        , remoteStorageCacheDir
        , remoteStorageSrcUrl
        , maxCachedChunks
        , prefetchAhead
        }
