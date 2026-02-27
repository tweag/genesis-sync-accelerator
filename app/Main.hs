{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import qualified Cardano.Tools.DBAnalyser.Block.Cardano as Cardano
import Cardano.Tools.DBAnalyser.HasAnalysis (mkProtocolInfo)
import Data.List (intercalate)
import Data.Void
import qualified GenesisSyncAccelerator.Diffusion as Diffusion
import GenesisSyncAccelerator.Parsers (parseAddr)
import qualified GenesisSyncAccelerator.RemoteStorage as RemoteStorage
import GenesisSyncAccelerator.Tracing (Tracers (..), startResourceTracer)
import GenesisSyncAccelerator.Types (HostAddr)
import Main.Utf8 (withStdTerminalHandles)
import qualified Network.Socket as Socket
import Options.Applicative
import Ouroboros.Consensus.Node.ProtocolInfo (ProtocolInfo (..))
import System.IO (BufferMode (..), hSetBuffering, stdout)
import "contra-tracer" Control.Tracer (showTracing, stdoutTracer, traceWith)

main :: IO ()
main = withStdTerminalHandles $ do
  hSetBuffering stdout LineBuffering
  cryptoInit
  Opts
    { immDBDir
    , addr
    , port
    , configFile
    , rtsFrequency
    , remoteStorageCacheDir
    , remoteStorageSrcUrl
    , maxCachedChunks
    } <-
    execParser optsParser
  let sockAddr = Socket.SockAddrInet port hostAddr
       where
        hostAddr = Socket.tupleToHostAddress addr
      args = Cardano.CardanoBlockArgs configFile Nothing
      tracers =
        Tracers
          { blockFetchMessageTracer = showTracing stdoutTracer
          , blockFetchEventTracer = showTracing stdoutTracer
          , chainSyncMessageTracer = showTracing stdoutTracer
          , chainSyncEventTracer = showTracing stdoutTracer
          , remoteStorageTracer = showTracing stdoutTracer
          }
  ProtocolInfo{pInfoConfig} <- mkProtocolInfo args
  traceWith stdoutTracer $ "Running ImmDB server at " ++ printHost (addr, port)
  startResourceTracer stdoutTracer rtsFrequency
  let mbRemoteConfig = fmap (`RemoteStorage.RemoteStorageConfig` remoteStorageCacheDir) remoteStorageSrcUrl
  absurd
    <$> Diffusion.run
      mbRemoteConfig
      maxCachedChunks
      tracers
      immDBDir
      sockAddr
      pInfoConfig

type RTSFrequency = Int

-- | Command-line options for the Genesis Sync Accelerator.
data Opts = Opts
  { immDBDir :: FilePath
  -- ^ Local path to the ImmutableDB directory.
  -- TODO: Is this needed?
  , addr :: HostAddr
  -- ^ IP address to bind to.
  , port :: Socket.PortNumber
  -- ^ TCP port to listen on.
  , configFile :: FilePath
  -- ^ Path to the node configuration file.
  , rtsFrequency :: RTSFrequency
  -- ^ Frequency for tracing RTS statistics.
  , remoteStorageCacheDir :: String
  -- ^ Location of Sync Accelerator cache.
  , remoteStorageSrcUrl :: Maybe String
  -- ^ Optional CDN URL for the Genesis Sync Accelerator.
  , maxCachedChunks :: Int
  -- ^ Maximum number of chunks to keep in cache.
  }

printHost :: (HostAddr, Socket.PortNumber) -> String
printHost ((a, b, c, d), port) = intercalate "." subs ++ ":" ++ show port
 where
  subs = map show [a, b, c, d]

optsParser :: ParserInfo Opts
optsParser =
  info (helper <*> parse) $ fullDesc <> progDesc desc
 where
  desc = "Serve an ImmutableDB via ChainSync and BlockFetch"

  parse = do
    immDBDir <-
      strOption $
        mconcat
          [ long "db"
          , help "Path to the ImmutableDB"
          , metavar "PATH"
          ]
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
      option auto $
        mconcat
          [ long "rts-frequency"
          , help "Frequency (in milliseconds) to poll GHC RTS statistics"
          , value 1000
          , showDefault
          ]
    remoteStorageCacheDir <-
      strOption $
        mconcat
          [ long "rs-cache-url"
          , help "Path to possible cache dir for the Sync Accelerator"
          , value "/tmp/sync-accelerator/"
          , metavar "PATH"
          , showDefault
          ]
    remoteStorageSrcUrl <-
      optional $
        strOption $
          mconcat
            [ long "rs-src-url"
            , help
                "URL to a CDN serving ImmutableDB chunks (e.g. https://example.com/chain). If left empty, the sync accelerator is disabled."
            , metavar "URL"
            ]
    maxCachedChunks <-
      option auto $
        mconcat
          [ long "max-cached-chunks"
          , help "Maximum number of chunks to keep in cache"
          , value 10
          , showDefault
          ]
    pure
      Opts
        { immDBDir
        , addr
        , port
        , configFile
        , rtsFrequency
        , remoteStorageCacheDir
        , remoteStorageSrcUrl
        , maxCachedChunks
        }
