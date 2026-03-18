{-# LANGUAGE PackageImports #-}

module GenesisSyncAccelerator.Tracing
  ( BlockFetchEventTracer
  , BlockFetchMessageTracer
  , ChainSyncEventTracer
  , ChainSyncMessageTracer
  , RemoteStorageTracer
  , Tracers (..)
  , TraceDownloadFailure (..)
  , TraceRemoteStorageEvent (..)
  , startResourceTracer
  ) where

import Cardano.Logging.Resources (readResourceStats)
import Cardano.Logging.Types (LogFormatting (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Monad (forever)
import Control.Monad.Class.MonadAsync (link)
import Data.Text (unpack)
import Data.Word (Word64)
import GHC.Conc (labelThread, myThreadId)
import Ouroboros.Consensus.MiniProtocol.BlockFetch.Server
  ( TraceBlockFetchServerEvent
  )
import Ouroboros.Consensus.MiniProtocol.ChainSync.Server
  ( TraceChainSyncServerEvent
  )
import Ouroboros.Consensus.Storage.Serialisation
  ( SerialisedHeader
  )
import Ouroboros.Network.Block (Point, Serialised, Tip)
import Ouroboros.Network.Driver.Simple (TraceSendRecv)
import Ouroboros.Network.Protocol.BlockFetch.Type (BlockFetch)
import Ouroboros.Network.Protocol.ChainSync.Type (ChainSync)
import "contra-tracer" Control.Tracer (Tracer, contramap, traceWith)

type BlockFetchMessageTracer m blk =
  Tracer m (TraceSendRecv (BlockFetch (Serialised blk) (Point blk)))

type BlockFetchEventTracer m blk =
  Tracer m (TraceBlockFetchServerEvent blk)

type ChainSyncMessageTracer m blk =
  Tracer m (TraceSendRecv (ChainSync (SerialisedHeader blk) (Point blk) (Tip blk)))

type ChainSyncEventTracer m blk =
  Tracer m (TraceChainSyncServerEvent blk)

type RemoteStorageTracer m = Tracer m TraceRemoteStorageEvent

-- | Events traced by the Remote Storage client.
data TraceRemoteStorageEvent
  = -- | Starting download of a file.
    TraceDownloadStart String
  | -- | Successfully downloaded a file.
    TraceDownloadSuccess String Word64
  | -- | Failed to download a file.
    TraceDownloadFailure TraceDownloadFailure
  | -- | Starting download of tip metadata.
    TraceTipFetchStart !String
  | -- | Successfully fetched tip metadata.
    TraceTipFetchSuccess !String
  deriving (Eq, Show)

-- | Download failure reasons.
data TraceDownloadFailure
  = -- | Exception during download.
    TraceDownloadException String String
  | -- | Non-200 HTTP status.
    TraceDownloadError String Int
  deriving (Eq, Show)

data Tracers m blk = Tracers
  { blockFetchMessageTracer :: BlockFetchMessageTracer m blk
  , blockFetchEventTracer :: BlockFetchEventTracer m blk
  , chainSyncMessageTracer :: ChainSyncMessageTracer m blk
  , chainSyncEventTracer :: ChainSyncEventTracer m blk
  , remoteStorageTracer :: RemoteStorageTracer m
  }

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
