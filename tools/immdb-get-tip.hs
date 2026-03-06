{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import qualified Cardano.Tools.DBAnalyser.Block.Cardano as Cardano
import Cardano.Tools.DBAnalyser.HasAnalysis (mkProtocolInfo)
import Control.ResourceRegistry (runWithTempRegistry, withRegistry)
import GHC.Conc (atomically)
import GenesisSyncAccelerator.Tracing (startResourceTracer)
import Main.Utf8 (withStdTerminalHandles)
import Options.Applicative
import Ouroboros.Consensus.Block (GetPrevHash)
import Ouroboros.Consensus.Config (TopLevelConfig, configCodec, configStorage)
import Ouroboros.Consensus.Node.InitStorage
  ( NodeInitStorage (nodeCheckIntegrity, nodeImmutableDbChunkInfo)
  )
import Ouroboros.Consensus.Node.ProtocolInfo (ProtocolInfo (..))
import Ouroboros.Consensus.Node.Run (SerialiseNodeToNodeConstraints)
import Ouroboros.Consensus.Storage.ImmutableDB (ImmutableDbArgs (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmutableDB
import System.FS.API (SomeHasFS (..))
import System.FS.API.Types (MountPoint (MountPoint))
import System.FS.IO (ioHasFS)
import "contra-tracer" Control.Tracer (stdoutTracer, traceWith)

type RTSFrequency = Int

data Opts = Opts
  { immDBDir :: FilePath
  -- ^ Local path to the ImmutableDB directory.
  , configFile :: FilePath
  -- ^ Path to the node configuration file.
  , rtsFrequency :: RTSFrequency
  -- ^ Frequency for tracing RTS statistics.
  }

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
    pure
      Opts
        { immDBDir
        , configFile
        , rtsFrequency
        }

run ::
  forall blk.
  ( GetPrevHash blk
  , SerialiseNodeToNodeConstraints blk
  , ImmutableDB.ImmutableDbSerialiseConstraints blk
  , NodeInitStorage blk
  ) =>
  FilePath ->
  TopLevelConfig blk ->
  IO ()
run immDBDir cfg = withRegistry \registry ->
  ImmutableDB.withDB
    (ImmutableDB.openDB (immDBArgs registry) runWithTempRegistry)
    \immDB -> do
      tip <- atomically $ ImmutableDB.getTip immDB
      traceWith stdoutTracer $ "ImmutableDB opened, tip is " ++ show tip
 where
  hasFS = ioHasFS $ MountPoint immDBDir
  immDBArgs registry =
    ImmutableDB.defaultArgs
      { immCheckIntegrity = nodeCheckIntegrity storageCfg
      , immChunkInfo = nodeImmutableDbChunkInfo storageCfg
      , immCodecConfig = codecCfg
      , immRegistry = registry
      , immHasFS = SomeHasFS hasFS
      }
  codecCfg = configCodec cfg
  storageCfg = configStorage cfg

main :: IO ()
main = withStdTerminalHandles $ do
  cryptoInit
  Opts
    { immDBDir
    , configFile
    , rtsFrequency
    } <-
    execParser optsParser
  ProtocolInfo{pInfoConfig} <- mkProtocolInfo $ Cardano.CardanoBlockArgs configFile Nothing
  startResourceTracer stdoutTracer rtsFrequency
  run immDBDir pInfoConfig
