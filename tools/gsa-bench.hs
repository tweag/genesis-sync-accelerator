{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Synthetic Cardano node-to-node client that pulls blocks from a running GSA
-- as fast as possible and reports throughput.
--
-- Drives ChainSync to track the server's tip and BlockFetch to stream block
-- ranges in realistic batches, mirroring what a real cardano-node does but
-- without any chain validation, header reconstruction, or consensus logic.
-- Payload bytes are counted via @BL.length@ on the @Serialised blk@ CBOR
-- wrapper — so the benchmark is schema-independent.
module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, link, wait)
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , TVar
  , atomically
  , lengthTBQueue
  , modifyTVar'
  , newTBQueueIO
  , newTVarIO
  , readTBQueue
  , readTVar
  , readTVarIO
  , retry
  , writeTBQueue
  , writeTVar
  )
import Control.Exception (displayException)
import Control.Monad (replicateM, unless, when)
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (for_)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Time.Clock
  ( UTCTime
  , diffUTCTime
  , getCurrentTime
  )
import Data.Void (Void)
import Data.Word (Word64)
import GenesisSyncAccelerator.Util (getTopLevelConfig)
import Main.Utf8 (withStdTerminalHandles)
import qualified Network.Mux as Mux
import Network.Socket (HostName, PortNumber)
import qualified Network.Socket as Socket
import Options.Applicative
import Ouroboros.Consensus.Block
import Ouroboros.Consensus.Cardano.Block (CardanoBlock, StandardCrypto)
import Ouroboros.Consensus.Config
import Ouroboros.Consensus.Config.SupportsNode (getNetworkMagic)
import qualified Ouroboros.Consensus.Network.NodeToNode as Consensus.N2N
import Ouroboros.Consensus.Node (stdVersionDataNTN)
import Ouroboros.Consensus.Node.NetworkProtocolVersion
  ( supportedNodeToNodeVersions
  )
import Ouroboros.Network.Block
  ( Serialised (..)
  , Tip (..)
  , getTipPoint
  )
import Ouroboros.Network.Driver.Simple (runPeer, runPipelinedPeer)
import qualified Ouroboros.Network.IOManager as IOManager
import Ouroboros.Network.Magic (NetworkMagic)
import Ouroboros.Network.Mux
  ( MiniProtocol (..)
  , MiniProtocolCb (..)
  , OuroborosApplication (..)
  , OuroborosApplicationWithMinimalCtx
  , RunMiniProtocol (..)
  , mkMiniProtocolCbFromPeer
  )
import Ouroboros.Network.NodeToNode (NodeToNodeVersion, NodeToNodeVersionData)
import qualified Ouroboros.Network.NodeToNode as N2N
import Ouroboros.Network.PeerSelection.PeerSharing (PeerSharing (..))
import Ouroboros.Network.PeerSelection.PeerSharing.Codec
  ( decodeRemoteAddress
  , encodeRemoteAddress
  )
import Ouroboros.Network.Protocol.BlockFetch.Type
  ( BlockFetch (..)
  , ChainRange (..)
  , Message (..)
  )
import Network.TypedProtocol.Core
import Network.TypedProtocol.Peer.Client
import Ouroboros.Network.Protocol.ChainSync.Client
  ( ChainSyncClient (..)
  , ClientStIdle (..)
  , ClientStIntersect (..)
  , ClientStNext (..)
  , chainSyncClientPeer
  )
import Ouroboros.Network.Protocol.Handshake.Version (Version (..), Versions (..))
import Ouroboros.Network.Protocol.KeepAlive.Client
  ( KeepAliveClient (..)
  , keepAliveClientPeer
  )
import qualified Ouroboros.Network.Snocket as Snocket
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)
import "contra-tracer" Control.Tracer (nullTracer)

-- ─── CLI ──────────────────────────────────────────────────────────────────────

data Opts = Opts
  { oHost :: HostName
  , oPort :: PortNumber
  , oNodeConfig :: FilePath
  , oParallel :: Int
  , oMaxInFlight :: Int
  , oMaxBlocks :: Maybe Word64
  , oDuration :: Maybe Double
  , oReportInterval :: Double
  , oBatchSize :: Int
  }

optsParser :: ParserInfo Opts
optsParser =
  info (helper <*> parse) $ fullDesc <> progDesc desc
 where
  desc =
    "Drive ChainSync+BlockFetch against a running GSA and report blocks/s, MB/s"

  parse = do
    oHost <-
      strOption $
        long "host"
          <> help "GSA host (default 127.0.0.1)"
          <> metavar "HOST"
          <> value "127.0.0.1"
          <> showDefault
    oPort <-
      option (auto @Word64 >>= pure . fromIntegral) $
        long "port"
          <> help "GSA port (default 3001)"
          <> metavar "PORT"
          <> value 3001
          <> showDefault
    oNodeConfig <-
      strOption $
        long "node-config"
          <> help "Path to Cardano node config JSON (same file the GSA reads)"
          <> metavar "PATH"
    oParallel <-
      option auto $
        long "parallel"
          <> help "Number of concurrent fake-node connections (default 1). Each connection opens a separate TCP stream — models the multi-peer case, not single-peer pipelining (use --max-in-flight for that)."
          <> metavar "N"
          <> value 1
          <> showDefault
    oMaxInFlight <-
      option auto $
        long "max-in-flight"
          <> help "Maximum outstanding BlockFetch MsgRequestRange per connection (default 10, cap 100). This is the cardano-node-shaped concurrency knob: multiple ranges pipelined on a single TCP connection. Set to 1 for non-pipelined behaviour."
          <> metavar "K"
          <> value 10
          <> showDefault
    oMaxBlocks <-
      optional $
        option auto $
          long "max-blocks"
            <> help "Stop after receiving this many blocks (aggregate)"
            <> metavar "N"
    oDuration <-
      optional $
        option auto $
          long "duration"
            <> help "Stop after this many seconds of wall time"
            <> metavar "SECS"
    oReportInterval <-
      option auto $
        long "report-interval"
          <> help "Seconds between progress lines (default 5)"
          <> metavar "SECS"
          <> value 5
          <> showDefault
    oBatchSize <-
      option auto $
        long "batch-size"
          <> help "Points per BlockFetch MsgRequestRange (default 500)"
          <> metavar "N"
          <> value 500
          <> showDefault
    pure Opts{..}

-- ─── Stats ───────────────────────────────────────────────────────────────────

-- | Per-client counter. Each client mutates only its own counter; the reporter
-- reads all counters and sums. Keeps the hot path contention-free.
data ClientCounter = ClientCounter
  { ccBlocks :: !(TVar Word64)
  , ccBytes :: !(TVar Word64)
  }

newClientCounter :: IO ClientCounter
newClientCounter = ClientCounter <$> newTVarIO 0 <*> newTVarIO 0

addBlock :: ClientCounter -> Word64 -> STM ()
addBlock ClientCounter{ccBlocks, ccBytes} nBytes = do
  modifyTVar' ccBlocks (+ 1)
  modifyTVar' ccBytes (+ nBytes)

readCounter :: ClientCounter -> STM (Word64, Word64)
readCounter ClientCounter{ccBlocks, ccBytes} =
  (,) <$> readTVar ccBlocks <*> readTVar ccBytes

aggregate :: [ClientCounter] -> STM (Word64, Word64)
aggregate = foldr step (pure (0, 0))
 where
  step c acc = do
    (bA, byA) <- acc
    (b, by) <- readCounter c
    pure (bA + b, byA + by)

-- ─── Protocol client glue ────────────────────────────────────────────────────

-- | Type alias to keep signatures short: the Cardano block the GSA serves.
type Blk = CardanoBlock StandardCrypto

-- | Shared state for one client connection.
data ClientState = ClientState
  { csCounter :: !ClientCounter
  , csStop :: !(TVar Bool)
  -- ^ Global stop flag (set by watchdog or max-blocks check).
  , csServerTip :: !(TVar (Point Blk))
  -- ^ Latest tip reported by the server over ChainSync. Updated by the
  -- ChainSync client thread, read by the BlockFetch client thread.
  , csHeaderQ :: !(TBQueue (Point Blk))
  -- ^ Bounded queue of block 'Point's extracted from each @MsgRollForward@
  -- header, pumped by ChainSync and drained by BlockFetch in batches. Acts
  -- as backpressure — when BlockFetch falls behind, ChainSync blocks on
  -- 'writeTBQueue' until drained.
  , csReachedTip :: !(TVar Bool)
  -- ^ Flipped to 'True' when the ChainSync server sends 'MsgAwaitReply'
  -- (i.e. we're at the server's current tip). BlockFetch uses this as the
  -- signal to drain any final partial batch and then send 'MsgClientDone'.
  }

newClientState :: ClientCounter -> TVar Bool -> Int -> Int -> IO ClientState
newClientState counter stop batchSize maxInFlight = do
  tip <- newTVarIO GenesisPoint
  -- Capacity must hold at least K outstanding batches + a few for headroom,
  -- otherwise ChainSync can't keep BlockFetch's pipeline full.
  let cap = fromIntegral (max 2048 ((maxInFlight + 4) * batchSize))
  q <- newTBQueueIO cap
  reachedTip <- newTVarIO False
  pure
    ClientState
      { csCounter = counter
      , csStop = stop
      , csServerTip = tip
      , csHeaderQ = q
      , csReachedTip = reachedTip
      }

-- ----- ChainSync client: extract Points, track the tip ----------------------
--
-- On connection we @MsgFindIntersect [Genesis]@ to anchor at the start of
-- chain. Each following @MsgRollForward@ delivers a typed 'Header Blk' from
-- which we derive the block's 'Point' via 'blockPoint' (+ 'castPoint' to land
-- in @Point Blk@). Points are pushed onto a bounded TBQueue that BlockFetch
-- drains in batches. If BlockFetch falls behind, the queue fills and
-- 'writeTBQueue' blocks — natural backpressure that gates ChainSync.

chainSyncBenchClient ::
  ClientState ->
  ChainSyncClient (Header Blk) (Point Blk) (Tip Blk) IO ()
chainSyncBenchClient st =
  ChainSyncClient $
    pure $
      SendMsgFindIntersect [GenesisPoint] intersect
 where
  updateTipThen :: Tip Blk -> ChainSyncClient (Header Blk) (Point Blk) (Tip Blk) IO ()
  updateTipThen tip = ChainSyncClient $ do
    atomically $ writeTVar (csServerTip st) (getTipPoint tip)
    runChainSyncClient requestLoop

  intersect =
    ClientStIntersect
      { recvMsgIntersectFound = \_pt tip -> updateTipThen tip
      , recvMsgIntersectNotFound = updateTipThen
      }

  requestLoop :: ChainSyncClient (Header Blk) (Point Blk) (Tip Blk) IO ()
  requestLoop = ChainSyncClient $ do
    stopped <- readTVarIO (csStop st)
    if stopped
      then pure (SendMsgDone ())
      else
        -- The @pure@ slot in 'SendMsgRequestNext' fires *exactly* when the
        -- server sends 'MsgAwaitReply', i.e. the server is stuck at tip.
        -- BlockFetch reads 'csReachedTip' to know "no more points coming,
        -- drain any remainder and close".
        pure $
          SendMsgRequestNext
            (atomically $ writeTVar (csReachedTip st) True)
            stNext

  stNext :: ClientStNext (Header Blk) (Point Blk) (Tip Blk) IO ()
  stNext =
    ClientStNext
      { recvMsgRollForward = \hdr tip -> ChainSyncClient $ do
          let pt = castPoint (blockPoint hdr) :: Point Blk
          atomically $ do
            writeTVar (csServerTip st) (getTipPoint tip)
            writeTBQueue (csHeaderQ st) pt
          runChainSyncClient requestLoop
      , recvMsgRollBackward = \_pt tip -> updateTipThen tip
      -- Rollbacks in practice only happen once (server rolls us back to
      -- the negotiated Genesis intersection), and our queue is empty at
      -- that point, so no draining needed. For a real mid-chain rollback
      -- we'd need to remove any queued Points strictly after @_pt@, but
      -- that case doesn't occur when benching against an ImmutableDB.
      }

-- ----- BlockFetch client: pipelined batched range requests -----------------
--
-- Mirror cardano-node's BlockFetch.Client behaviour: keep up to @K@
-- 'MsgRequestRange' requests outstanding on a single connection, pipelining
-- new requests before the previous batch's 'MsgBatchDone' lands. Each request
-- carries a @ChainRange@ covering up to @batchSize@ Points drained from
-- 'csHeaderQ'. Bytes are counted per received 'MsgBlock'.
--
-- This uses the lower-level typed-protocols 'Client' API (rather than the
-- higher-level 'BlockFetchSender' API) because step-by-step decisions need
-- to query the STM-backed header queue and stop flag — which 'BlockFetchSender'
-- can't express but 'Client'+'Effect' can.

blockFetchPipelinedBenchClient ::
  -- | batchSize
  Int ->
  -- | maxInFlight (K)
  Int ->
  ClientState ->
  ClientPipelined (BlockFetch (Serialised Blk) (Point Blk)) BFIdle IO ()
blockFetchPipelinedBenchClient batchSize maxInFlight st =
  ClientPipelined (sender Zero 0)
 where
  -- The 'Nat n' singleton tracks outstanding requests at the type level so
  -- we may legally 'Collect' (only allowed when n ≥ 1) and 'Done' (only
  -- allowed when n = 0). The 'Int' shadow is just so we can compare against
  -- 'maxInFlight' without an O(n) singleton-to-Int conversion every step.
  sender ::
    forall n.
    Nat n ->
    Int ->
    Client
      (BlockFetch (Serialised Blk) (Point Blk))
      ('Pipelined n ())
      'BFIdle
      IO
      ()
  sender outstanding inFlight = Effect $ do
    decision <- atomically (decide inFlight)
    pure (apply outstanding inFlight decision)

  decide :: Int -> STM StepAction
  decide inFlight = do
    stopped <- readTVar (csStop st)
    qLen <- lengthTBQueue (csHeaderQ st)
    reachedTip <- readTVar (csReachedTip st)
    let qLenI = fromIntegral qLen :: Int
        canSend = inFlight < maxInFlight
        haveOutstanding = inFlight > 0
    if stopped
      then
        if haveOutstanding
          then pure StepCollect -- drain the pipeline before terminating
          else pure StepDone
      else
        if canSend && qLenI >= batchSize
          then StepSend <$> drainN batchSize
          else
            if canSend && reachedTip && qLenI > 0
              then StepSend <$> drainN qLenI
              else
                if haveOutstanding
                  then pure StepCollect
                  else
                    if reachedTip
                      then pure StepDone -- nothing in flight, nothing to send, server idle
                      else retry -- block waiting for ChainSync to deliver more headers

  apply ::
    forall n.
    Nat n ->
    Int ->
    StepAction ->
    Client
      (BlockFetch (Serialised Blk) (Point Blk))
      ('Pipelined n ())
      'BFIdle
      IO
      ()
  apply outstanding _inFlight StepDone =
    case outstanding of
      Zero -> Yield MsgClientDone (Done ())
      Succ _ -> error "gsa-bench: StepDone with outstanding > 0 should be impossible"
  apply outstanding inFlight (StepSend pts) =
    YieldPipelined
      (MsgRequestRange (ChainRange (head pts) (lastOf pts (head pts))))
      (receiver pts)
      (sender (Succ outstanding) (inFlight + 1))
  apply outstanding inFlight StepCollect =
    case outstanding of
      Zero ->
        error "gsa-bench: StepCollect with no outstanding requests should be impossible"
      Succ n ->
        Collect
          Nothing
          (\() -> sender n (inFlight - 1))

  receiver ::
    [Point Blk] ->
    Receiver
      (BlockFetch (Serialised Blk) (Point Blk))
      'BFBusy
      'BFIdle
      IO
      ()
  receiver _pts =
    ReceiverAwait $ \case
      MsgStartBatch -> receiveBlocks
      MsgNoBlocks -> ReceiverDone ()
   where
    receiveBlocks ::
      Receiver
        (BlockFetch (Serialised Blk) (Point Blk))
        'BFStreaming
        'BFIdle
        IO
        ()
    receiveBlocks =
      ReceiverAwait $ \case
        MsgBlock (Serialised bs) -> ReceiverEffect $ do
          atomically $ addBlock (csCounter st) (fromIntegral (BL.length bs))
          pure receiveBlocks
        MsgBatchDone -> ReceiverDone ()

  -- Total replacement for @last@ — non-partial, requires a default.
  lastOf :: [a] -> a -> a
  lastOf [] d = d
  lastOf [x] _ = x
  lastOf (_ : xs) d = lastOf xs d

  drainN :: Int -> STM [Point Blk]
  drainN n = replicateM n (readTBQueue (csHeaderQ st))

data StepAction = StepDone | StepSend ![Point Blk] | StepCollect

-- ----- KeepAlive / TxSubmission stubs ----------------------------------------

-- | Keep-alive client that never pings and never terminates.
--
-- Critical subtlety: 'simpleMuxCallback' (what 'connectTo' uses internally)
-- waits for the *first* mini-protocol to finish and then cancels the rest.
-- A KeepAliveClient that returns 'SendMsgDone' ends up finishing immediately,
-- taking ChainSync and BlockFetch with it (AsyncCancelled). So we block
-- forever here; Mux never schedules any bytes for this protocol, and the
-- server-side @StartOnDemandAny@ responder stays idle too.
noopKeepAliveClient :: KeepAliveClient IO ()
noopKeepAliveClient = KeepAliveClient (atomically retry)

-- ─── Wire assembly ───────────────────────────────────────────────────────────

-- | Build the full initiator-side 'OuroborosApplication' for one connection.
-- Mirrors the four mini-protocols the GSA serves (keepAlive/chainSync/
-- blockFetch/txSubmission), using the same numbers, limits, and serialised
-- codecs.
benchApplication ::
  -- | batchSize (passed through to blockFetchPipelinedBenchClient)
  Int ->
  -- | maxInFlight (pipeline depth on the BlockFetch protocol)
  Int ->
  TopLevelConfig Blk ->
  ClientState ->
  Versions
    NodeToNodeVersion
    NodeToNodeVersionData
    ( OuroborosApplicationWithMinimalCtx
        'Mux.InitiatorMode
        Socket.SockAddr
        BL.ByteString
        IO
        ()
        Void
    )
benchApplication batchSize maxInFlight cfg st =
  Versions $ Map.mapWithKey mkVersion (supportedNodeToNodeVersions (Proxy @Blk))
 where
  networkMagic :: NetworkMagic
  networkMagic = getNetworkMagic (configBlock cfg)

  versionData =
    stdVersionDataNTN
      networkMagic
      N2N.InitiatorOnlyDiffusionMode
      PeerSharingDisabled

  codecCfg = configCodec cfg

  mkVersion version blockVersion =
    Version
      { versionApplication = const (application version blockVersion)
      , versionData
      }

  application version blockVersion =
    OuroborosApplication
      [ mkMP Mux.StartOnDemand N2N.keepAliveMiniProtocolNum keepAliveLims $
          mkMiniProtocolCbFromPeer $ \_ctx ->
            ( nullTracer
            , cKeepAliveCodec
            , keepAliveClientPeer noopKeepAliveClient
            )
      , mkMP Mux.StartEagerly N2N.chainSyncMiniProtocolNum chainSyncLims $
          MiniProtocolCb $ \_ctx channel ->
            runPeer
              nullTracer
              cChainSyncCodec
              channel
              (chainSyncClientPeer (chainSyncBenchClient st))
      , mkMP Mux.StartEagerly N2N.blockFetchMiniProtocolNum blockFetchLims $
          MiniProtocolCb $ \_ctx channel ->
            runPipelinedPeer
              nullTracer
              cBlockFetchCodecSerialised
              channel
              (blockFetchPipelinedBenchClient batchSize maxInFlight st)
      , mkMP Mux.StartOnDemand N2N.txSubmissionMiniProtocolNum txSubmissionLims $
          MiniProtocolCb (\_ _ -> atomically retry)
      ]
   where
    Consensus.N2N.Codecs
      { Consensus.N2N.cKeepAliveCodec
      , Consensus.N2N.cChainSyncCodec
      , Consensus.N2N.cBlockFetchCodecSerialised
      } =
        Consensus.N2N.defaultCodecs
          codecCfg
          blockVersion
          encodeRemoteAddress
          decodeRemoteAddress
          version

  params = N2N.defaultMiniProtocolParameters
  keepAliveLims = N2N.keepAliveProtocolLimits params
  chainSyncLims = N2N.chainSyncProtocolLimits params
  blockFetchLims = N2N.blockFetchProtocolLimits params
  txSubmissionLims = N2N.txSubmissionProtocolLimits params

  mkMP start num lims run =
    MiniProtocol
      { miniProtocolNum = num
      , miniProtocolStart = start
      , miniProtocolLimits = lims
      , miniProtocolRun = InitiatorProtocolOnly run
      }

-- ─── Client runner ───────────────────────────────────────────────────────────

runBenchClient ::
  -- | batchSize
  Int ->
  -- | maxInFlight
  Int ->
  Snocket.Snocket IO Socket.Socket Socket.SockAddr ->
  TopLevelConfig Blk ->
  Socket.SockAddr ->
  ClientState ->
  IO ()
runBenchClient batchSize maxInFlight sn cfg addr st = do
  result <-
    N2N.connectTo
      sn
      N2N.nullNetworkConnectTracers
      (benchApplication batchSize maxInFlight cfg st)
      Nothing
      addr
  case result of
    Left e -> do
      hPutStrLn stderr $ "[gsa-bench] client failed: " <> displayException e
      -- Any client failure flips the stop flag so the rest of the benchmark
      -- reports its terminal numbers and shuts down.
      atomically $ writeTVar (csStop st) True
    Right _ -> pure ()

-- ─── Reporter & watchdog ─────────────────────────────────────────────────────

data Snapshot = Snapshot
  { snapAt :: !UTCTime
  , snapBlocks :: !Word64
  , snapBytes :: !Word64
  }

snapshot :: [ClientCounter] -> IO Snapshot
snapshot counters = do
  (b, by) <- atomically (aggregate counters)
  now <- getCurrentTime
  pure (Snapshot now b by)

reporter :: Double -> UTCTime -> [ClientCounter] -> TVar Bool -> IO ()
reporter intervalSecs start counters stop = do
  hSetBuffering stdout LineBuffering
  loop =<< snapshot counters
 where
  intervalMicros = round (intervalSecs * 1_000_000)

  loop prev = do
    stopped <- readTVarIO stop
    if stopped
      then pure ()
      else do
        threadDelay intervalMicros
        cur <- snapshot counters
        let dt = realToFrac (diffUTCTime (snapAt cur) (snapAt prev)) :: Double
            total = realToFrac (diffUTCTime (snapAt cur) start) :: Double
            db = snapBlocks cur - snapBlocks prev
            dby = snapBytes cur - snapBytes prev
            bps = if dt > 0 then fromIntegral db / dt else 0 :: Double
            mbps = if dt > 0 then fromIntegral dby / dt / 1_048_576 else 0 :: Double
        putStrLn $
          concat
            [ "[t=" ++ formatDouble 6 1 total ++ "s] "
            , "blocks=" ++ show (snapBlocks cur)
            , " (+" ++ show db ++ "  " ++ formatDouble 10 1 bps ++ "/s)  "
            , "bytes=" ++ formatBytes (snapBytes cur)
            , " (+" ++ formatBytes dby ++ "  " ++ formatDouble 10 2 mbps ++ " MB/s)"
            ]
        loop cur

watchdog ::
  Maybe Word64 ->
  Maybe Double ->
  UTCTime ->
  [ClientCounter] ->
  TVar Bool ->
  IO ()
watchdog mMaxBlocks mDuration start counters stop = loop
 where
  pollMicros = 200_000

  loop = do
    stopped <- readTVarIO stop
    unless stopped $ do
      (b, _) <- atomically (aggregate counters)
      now <- getCurrentTime
      let elapsed = realToFrac (diffUTCTime now start) :: Double
          hitBlocks = maybe False (b >=) mMaxBlocks
          hitTime = maybe False (elapsed >=) mDuration
      if hitBlocks || hitTime
        then atomically (writeTVar stop True)
        else do
          threadDelay pollMicros
          loop

-- ─── Formatting helpers ─────────────────────────────────────────────────────

formatDouble :: Int -> Int -> Double -> String
formatDouble width decimals x =
  let s = showFFixed decimals x
   in replicate (max 0 (width - length s)) ' ' ++ s
 where
  showFFixed d n =
    let factor = 10 ^^ d :: Double
        rounded = fromIntegral (round (n * factor) :: Integer) / factor :: Double
     in showWithDecimals d rounded
  showWithDecimals d n
    | d <= 0 = show (truncate n :: Integer)
    | otherwise =
        let whole = truncate n :: Integer
            frac = abs (n - fromIntegral whole)
            fracStr = take d (drop 2 (show (frac + 1))) -- "1.12345" -> "12345"
         in show whole ++ "." ++ pad d fracStr
  pad d s = s ++ replicate (d - length s) '0'

formatBytes :: Word64 -> String
formatBytes n
  | n < k = show n ++ " B"
  | n < m = formatDouble 0 2 (fromIntegral n / fromIntegral k) ++ " KB"
  | n < g = formatDouble 0 2 (fromIntegral n / fromIntegral m) ++ " MB"
  | n < t = formatDouble 0 2 (fromIntegral n / fromIntegral g) ++ " GB"
  | otherwise = formatDouble 0 2 (fromIntegral n / fromIntegral t) ++ " TB"
 where
  k = 1_024 :: Word64
  m = k * 1_024
  g = m * 1_024
  t = g * 1_024

-- Escape a string value for our minimal JSON emitter.
jsonString :: String -> String
jsonString s = '"' : concatMap esc s ++ "\""
 where
  esc '"' = "\\\""
  esc '\\' = "\\\\"
  esc c = [c]

finalSummary ::
  UTCTime ->
  Int ->
  [ClientCounter] ->
  IO ()
finalSummary start clients counters = do
  (b, by) <- atomically (aggregate counters)
  now <- getCurrentTime
  let dt = realToFrac (diffUTCTime now start) :: Double
      bps = if dt > 0 then fromIntegral b / dt else 0 :: Double
      mbps = if dt > 0 then fromIntegral by / dt / 1_048_576 else 0 :: Double
  putStrLn $
    "{"
      <> intercalate
        ","
        [ pair "duration_s" (formatDouble 0 3 dt)
        , pair "clients" (show clients)
        , pair "blocks" (show b)
        , pair "bytes" (show by)
        , pair "blocks_per_sec" (formatDouble 0 3 bps)
        , pair "mb_per_sec" (formatDouble 0 3 mbps)
        ]
      <> "}"
 where
  pair k v = jsonString k <> ":" <> v

-- ─── Main ────────────────────────────────────────────────────────────────────

main :: IO ()
main = withStdTerminalHandles $ do
  hSetBuffering stdout LineBuffering
  cryptoInit
  opts <- execParser optsParser
  when (oParallel opts < 1) $ do
    hPutStrLn stderr "--parallel must be >= 1"
    exitFailure
  when (oMaxInFlight opts < 1 || oMaxInFlight opts > 100) $ do
    hPutStrLn stderr "--max-in-flight must be in [1, 100] (cap matches blockFetchPipeliningMax)"
    exitFailure
  cfg <- getTopLevelConfig (oNodeConfig opts)
  addr <- resolveAddr (oHost opts) (oPort opts)
  hPutStrLn stderr $
    "[gsa-bench] target="
      <> oHost opts
      <> ":"
      <> show (oPort opts)
      <> " parallel="
      <> show (oParallel opts)
      <> " max-in-flight="
      <> show (oMaxInFlight opts)
      <> " batch-size="
      <> show (oBatchSize opts)

  IOManager.withIOManager $ \iocp -> do
    let sn = Snocket.socketSnocket iocp

    stop <- newTVarIO False
    counters <-
      sequence
        [ newClientCounter | _ <- [1 .. oParallel opts]
        ]
    states <-
      traverse
        (\c -> newClientState c stop (oBatchSize opts) (oMaxInFlight opts))
        counters

    start <- getCurrentTime

    reporterThread <- async (reporter (oReportInterval opts) start counters stop)
    link reporterThread

    watchdogThread <-
      async
        ( watchdog
            (oMaxBlocks opts)
            (oDuration opts)
            start
            counters
            stop
        )
    link watchdogThread

    clientThreads :: [Async ()] <-
      traverse
        (async . runBenchClient (oBatchSize opts) (oMaxInFlight opts) sn cfg addr)
        states
    for_ clientThreads link

    mapM_ wait clientThreads
    -- Clients done → ensure stop is flipped so the reporter wraps up.
    atomically $ writeTVar stop True
    cancel reporterThread
    cancel watchdogThread

    finalSummary start (oParallel opts) counters

resolveAddr :: HostName -> PortNumber -> IO Socket.SockAddr
resolveAddr host port = do
  let hints =
        Socket.defaultHints
          { Socket.addrSocketType = Socket.Stream
          , Socket.addrFamily = Socket.AF_INET
          }
  ais <- Socket.getAddrInfo (Just hints) (Just host) (Just (show port))
  case ais of
    (ai : _) -> pure (Socket.addrAddress ai)
    [] -> do
      hPutStrLn stderr $ "could not resolve host " <> host
      exitFailure
