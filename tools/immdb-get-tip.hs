{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import GenesisSyncAccelerator.Tracing (startResourceTracer)
import GenesisSyncAccelerator.Util (getImmDbTip, getTopLevelConfig)
import Main.Utf8 (withStdTerminalHandles)
import Options.Applicative
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
  desc = "Print the tip of a local ImmutableDB"

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

main :: IO ()
main = withStdTerminalHandles $ do
  cryptoInit
  Opts{immDBDir, configFile, rtsFrequency} <- execParser optsParser
  cfg <- getTopLevelConfig configFile
  startResourceTracer stdoutTracer rtsFrequency
  tip <- getImmDbTip cfg immDBDir
  traceWith stdoutTracer $ "ImmutableDB tip: " ++ show tip
