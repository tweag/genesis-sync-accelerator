{-# LANGUAGE PackageImports #-}

module GenesisSyncAccelerator.Tracing (startResourceTracer) where

import Cardano.Logging.Resources (readResourceStats)
import Cardano.Logging.Types (LogFormatting (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Monad (forever)
import Control.Monad.Class.MonadAsync (link)
import Data.Text (unpack)
import GHC.Conc (labelThread, myThreadId)
import "contra-tracer" Control.Tracer (Tracer, contramap, traceWith)

-- | Starts a background thread to periodically trace resource statistics.
-- The thread reads resource stats and traces them using the given tracer.
-- It is linked to the parent thread to ensure proper error propagation.
startResourceTracer :: Tracer IO String -> Int -> IO ()
startResourceTracer _ 0 = pure ()
startResourceTracer trBase delayMilliseconds = async resourceThread >>= link
 where
  trStats = contramap (unpack . forHuman) trBase
  -- The background thread that periodically traces resource stats.
  resourceThread :: IO ()
  resourceThread = do
    -- Label the thread for easier debugging and identification.
    myThreadId >>= flip labelThread "Resource Stats Tracer"
    forever $ do
      readResourceStats >>= maybe (traceWith trBase "No resource stats available") (traceWith trStats)
      threadDelay (delayMilliseconds * 1000)
