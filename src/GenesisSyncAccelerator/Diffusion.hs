{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}

module GenesisSyncAccelerator.Diffusion (run) where

import qualified Data.ByteString.Lazy as BL
import Data.Functor.Contravariant ((>$<))
import Data.Void (Void)
import GenesisSyncAccelerator.MiniProtocols (genesisSyncAccelerator)
import qualified GenesisSyncAccelerator.OnDemand as OnDemand
import qualified GenesisSyncAccelerator.RemoteStorage as RemoteStorage
import GenesisSyncAccelerator.Tracing (Tracers (..))
import GenesisSyncAccelerator.Types (MaxCachedChunksCount, PrefetchChunksCount)
import GenesisSyncAccelerator.Util (fpToHasFS)
import qualified Network.Mux as Mux
import Network.Socket (SockAddr (..))
import Ouroboros.Consensus.Block
import Ouroboros.Consensus.Config
import Ouroboros.Consensus.Config.SupportsNode
import Ouroboros.Consensus.Node.InitStorage
  ( NodeInitStorage (nodeCheckIntegrity, nodeImmutableDbChunkInfo)
  )
import Ouroboros.Consensus.Node.NetworkProtocolVersion
import Ouroboros.Consensus.Node.Run (SerialiseNodeToNodeConstraints)
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmutableDB
import Ouroboros.Consensus.Util (ShowProxy)
import Ouroboros.Consensus.Util.IOLike
import Ouroboros.Network.IOManager (withIOManager)
import Ouroboros.Network.Mux
import qualified Ouroboros.Network.NodeToNode as N2N
import Ouroboros.Network.PeerSelection.PeerSharing.Codec
  ( decodeRemoteAddress
  , encodeRemoteAddress
  )
import Ouroboros.Network.Protocol.Handshake (HandshakeArguments (..))
import qualified Ouroboros.Network.Protocol.Handshake as Handshake
import qualified Ouroboros.Network.Server.Simple as Server
import qualified Ouroboros.Network.Snocket as Snocket
import Ouroboros.Network.Socket (SomeResponderApplication (..), configureSocket)
import "contra-tracer" Control.Tracer

-- | Glue code for using just the bits from the Diffusion Layer that we need in
-- this context.
serve ::
  SockAddr ->
  N2N.Versions
    N2N.NodeToNodeVersion
    N2N.NodeToNodeVersionData
    (OuroborosApplicationWithMinimalCtx 'Mux.ResponderMode SockAddr BL.ByteString IO Void ()) ->
  IO Void
serve sockAddr application = withIOManager \iocp ->
  Server.with
    (Snocket.socketSnocket iocp)
    Snocket.makeSocketBearer
    (\sock addr -> configureSocket sock (Just addr))
    sockAddr
    HandshakeArguments
      { haHandshakeTracer = show >$< stdoutTracer
      , haBearerTracer = show >$< stdoutTracer
      , haHandshakeCodec = Handshake.nodeToNodeHandshakeCodec
      , haVersionDataCodec = Handshake.cborTermVersionDataCodec N2N.nodeToNodeCodecCBORTerm
      , haAcceptVersion = Handshake.acceptableVersion
      , haQueryVersion = Handshake.queryVersion
      , haTimeLimits = Handshake.timeLimitsHandshake
      }
    (SomeResponderApplication <$> application)
    (\_ serverAsync -> wait serverAsync)

-- | Main entry point for the ImmutableDB server diffusion layer.
--
-- This function initializes the on-demand fetching runtime and starts the
-- network server to handle 'ChainSync' and 'BlockFetch' requests.
run ::
  forall blk.
  ( GetPrevHash blk
  , ShowProxy blk
  , SupportedNetworkProtocolVersion blk
  , SerialiseNodeToNodeConstraints blk
  , ImmutableDB.ImmutableDbSerialiseConstraints blk
  , NodeInitStorage blk
  , ConfigSupportsNode blk
  ) =>
  -- | Configuration for the Genesis Sync Accelerator (CDN fetching)
  RemoteStorage.RemoteStorageConfig ->
  MaxCachedChunksCount ->
  PrefetchChunksCount ->
  Tracers IO blk ->
  SockAddr ->
  TopLevelConfig blk ->
  IO Void
run remoteCfg maxCachedChunks prefetchAhead tracers sockAddr cfg = do
  let cacheDir = RemoteStorage.rscDstDir remoteCfg
      hasFS = fpToHasFS cacheDir
  onDemand <-
    OnDemand.newOnDemandRuntime
      OnDemand.OnDemandConfig
        { OnDemand.odcRemote = remoteCfg
        , OnDemand.odcTracer = remoteStorageTracer tracers
        , OnDemand.odcChunkInfo = nodeImmutableDbChunkInfo storageCfg
        , OnDemand.odcHasFS = hasFS
        , OnDemand.odcCodecConfig = codecCfg
        , OnDemand.odcCheckIntegrity = nodeCheckIntegrity storageCfg
        , OnDemand.odcMaxCachedChunks = maxCachedChunks
        , OnDemand.odcPrefetchAhead = prefetchAhead
        }
  serve sockAddr $
    genesisSyncAccelerator
      tracers
      codecCfg
      encodeRemoteAddress
      decodeRemoteAddress
      onDemand
      networkMagic
 where
  codecCfg = configCodec cfg
  storageCfg = configStorage cfg
  networkMagic = getNetworkMagic . configBlock $ cfg
