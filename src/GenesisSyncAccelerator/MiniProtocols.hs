-- TODO: Most of this code is copied from Ouroborus-consenses, copyright should belong to them.
-- See: https://github.com/tweag/genesis-sync-accelerator/issues/22
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module GenesisSyncAccelerator.MiniProtocols (genesisSyncAccelerator) where

import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Encoding as CBOR
import Control.Monad.IO.Class (MonadIO)
import Control.ResourceRegistry
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Functor ((<&>))
import qualified Data.Map.Strict as Map
import Data.Void (Void)
import GHC.Generics (Generic)
import qualified GenesisSyncAccelerator.OnDemand as OnDemand
import GenesisSyncAccelerator.Tracing (BlockFetchEventTracer, ChainSyncEventTracer, Tracers (..))
import qualified Network.Mux as Mux
import Ouroboros.Consensus.Block
import Ouroboros.Consensus.MiniProtocol.BlockFetch.Server (blockFetchServer')
import Ouroboros.Consensus.MiniProtocol.ChainSync.Server (chainSyncServerForFollower)
import Ouroboros.Consensus.Network.NodeToNode (Codecs (..))
import qualified Ouroboros.Consensus.Network.NodeToNode as Consensus.N2N
import Ouroboros.Consensus.Node (stdVersionDataNTN)
import Ouroboros.Consensus.Node.NetworkProtocolVersion
import Ouroboros.Consensus.Node.Run (SerialiseNodeToNodeConstraints)
import Ouroboros.Consensus.Storage.ChainDB.API (Follower (..))
import qualified Ouroboros.Consensus.Storage.ChainDB.API as ChainDB
import Ouroboros.Consensus.Storage.Common
import qualified Ouroboros.Consensus.Storage.ImmutableDB.API as ImmutableDB
import Ouroboros.Consensus.Storage.Serialisation
  ( DecodeDisk
  , DecodeDiskDep
  , ReconstructNestedCtxt
  )
import Ouroboros.Consensus.Util
import Ouroboros.Consensus.Util.IOLike
import Ouroboros.Network.Block (ChainUpdate (..), Tip (..))
import Ouroboros.Network.Driver (runPeer)
import Ouroboros.Network.KeepAlive (keepAliveServer)
import Ouroboros.Network.Magic (NetworkMagic)
import Ouroboros.Network.Mux
  ( MiniProtocol (..)
  , MiniProtocolCb (..)
  , OuroborosApplication (..)
  , OuroborosApplicationWithMinimalCtx
  , RunMiniProtocol (..)
  )
import Ouroboros.Network.NodeToNode
  ( NodeToNodeVersionData (..)
  , Versions (..)
  )
import qualified Ouroboros.Network.NodeToNode as N2N
import Ouroboros.Network.PeerSelection.PeerSharing (PeerSharing (..))
import Ouroboros.Network.Protocol.BlockFetch.Server
import Ouroboros.Network.Protocol.ChainSync.Server
import Ouroboros.Network.Protocol.Handshake.Version (Version (..))
import Ouroboros.Network.Protocol.KeepAlive.Server
  ( keepAliveServerPeer
  )
import "contra-tracer" Control.Tracer

genesisSyncAccelerator ::
  forall m blk addr h.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ShowProxy blk
  , SerialiseNodeToNodeConstraints blk
  , SupportedNetworkProtocolVersion blk
  ) =>
  Tracers m blk ->
  CodecConfig blk ->
  (NodeToNodeVersion -> addr -> CBOR.Encoding) ->
  (NodeToNodeVersion -> forall s. CBOR.Decoder s addr) ->
  OnDemand.OnDemandRuntime m blk h ->
  NetworkMagic ->
  Versions
    NodeToNodeVersion
    NodeToNodeVersionData
    (OuroborosApplicationWithMinimalCtx 'Mux.ResponderMode addr BL.ByteString m Void ())
genesisSyncAccelerator Tracers{..} codecCfg encAddr decAddr onDemand networkMagic = do
  forAllVersions application
 where
  forAllVersions ::
    (NodeToNodeVersion -> BlockNodeToNodeVersion blk -> r) ->
    Versions NodeToNodeVersion NodeToNodeVersionData r
  forAllVersions mkR =
    Versions $
      Map.mapWithKey mkVersion $
        supportedNodeToNodeVersions (Proxy @blk)
   where
    mkVersion version blockVersion =
      Version
        { versionApplication = const $ mkR version blockVersion
        , versionData =
            stdVersionDataNTN
              networkMagic
              N2N.InitiatorOnlyDiffusionMode
              PeerSharingDisabled
        }

  application ::
    NodeToNodeVersion ->
    BlockNodeToNodeVersion blk ->
    OuroborosApplicationWithMinimalCtx 'Mux.ResponderMode addr BL.ByteString m Void ()
  application version blockVersion =
    OuroborosApplication miniprotocols
   where
    miniprotocols =
      [ mkMiniProtocol
          Mux.StartOnDemandAny
          N2N.keepAliveMiniProtocolNum
          N2N.keepAliveProtocolLimits
          keepAliveProt
      , mkMiniProtocol
          Mux.StartOnDemand
          N2N.chainSyncMiniProtocolNum
          N2N.chainSyncProtocolLimits
          chainSyncProt
      , mkMiniProtocol
          Mux.StartOnDemand
          N2N.blockFetchMiniProtocolNum
          N2N.blockFetchProtocolLimits
          blockFetchProt
      , mkMiniProtocol
          Mux.StartOnDemand
          N2N.txSubmissionMiniProtocolNum
          N2N.txSubmissionProtocolLimits
          txSubmissionProt
      ]
     where
      Consensus.N2N.Codecs
        { cKeepAliveCodec
        , cChainSyncCodecSerialised
        , cBlockFetchCodecSerialised
        } =
          Consensus.N2N.defaultCodecs codecCfg blockVersion encAddr decAddr version

      keepAliveProt =
        MiniProtocolCb $ \_ctx channel ->
          runPeer nullTracer cKeepAliveCodec channel $
            keepAliveServerPeer keepAliveServer
      chainSyncProt =
        MiniProtocolCb $ \_ctx channel ->
          withRegistry $
            runPeer chainSyncMessageTracer cChainSyncCodecSerialised channel
              . chainSyncServerPeer
              . chainSyncServer chainSyncEventTracer onDemand ChainDB.getSerialisedHeaderWithPoint
      blockFetchProt =
        MiniProtocolCb $ \_ctx channel ->
          withRegistry $
            runPeer blockFetchMessageTracer cBlockFetchCodecSerialised channel
              . blockFetchServerPeer
              . blockFetchServer blockFetchEventTracer onDemand ChainDB.getSerialisedBlockWithPoint
      txSubmissionProt =
        -- never reply, there is no timeout
        MiniProtocolCb $ \_ctx _channel -> sleepForever

    mkMiniProtocol miniProtocolStart miniProtocolNum limits proto =
      MiniProtocol
        { miniProtocolNum
        , miniProtocolLimits = limits N2N.defaultMiniProtocolParameters
        , miniProtocolRun = ResponderProtocolOnly proto
        , miniProtocolStart
        }

-- | The ChainSync specification requires sending a rollback instruction to the
-- intersection point right after an intersection has been negotiated. (Opening
-- a connection implicitly negotiates the Genesis point as the intersection.)
data ChainSyncIntersection blk
  = JustNegotiatedIntersection !(Point blk)
  | AlreadySentRollbackToIntersection
  deriving stock Generic
  deriving anyclass NoThunks

chainSyncServer ::
  forall m blk a h.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  ChainSyncEventTracer m blk ->
  OnDemand.OnDemandRuntime m blk h ->
  BlockComponent blk (ChainDB.WithPoint blk a) ->
  ResourceRegistry m ->
  ChainSyncServer a (Point blk) (Tip blk) m ()
chainSyncServer tr onDemand blockComponent _registry = ChainSyncServer $ do
  follower <- newImmutableDBFollower
  runChainSyncServer $
    chainSyncServerForFollower tr getImmutableTip follower
 where
  newImmutableDBFollower :: m (Follower m blk (ChainDB.WithPoint blk a))
  newImmutableDBFollower = do
    varIterator <-
      newTVarIO
        =<< OnDemand.onDemandIteratorFrom
          onDemand
          blockComponent
          (StreamFromExclusive GenesisPoint)
    varIntersection <-
      newTVarIO $ JustNegotiatedIntersection GenesisPoint
    let getNextBlock = do
          iterator <- readTVarIO varIterator
          ImmutableDB.iteratorNext iterator >>= \case
            ImmutableDB.IteratorExhausted -> return Nothing
            ImmutableDB.IteratorResult a -> return (Just a)

        followerInstructionBlocking =
          readTVarIO varIntersection >>= \case
            JustNegotiatedIntersection intersectionPt -> do
              atomically $
                writeTVar varIntersection AlreadySentRollbackToIntersection
              pure $ RollBack intersectionPt
            AlreadySentRollbackToIntersection ->
              getNextBlock >>= maybe sleepForever (pure . AddBlock)

        followerInstructionNonBlocking =
          readTVarIO varIntersection >>= \case
            JustNegotiatedIntersection intersectionPt -> do
              atomically $
                writeTVar varIntersection AlreadySentRollbackToIntersection
              pure $ Just $ RollBack intersectionPt
            AlreadySentRollbackToIntersection ->
              fmap AddBlock <$> getNextBlock

        followerClose = ImmutableDB.iteratorClose =<< readTVarIO varIterator

        followerForward [] = pure Nothing
        followerForward (pt : _pts) =
          OnDemand.onDemandIteratorFrom onDemand blockComponent (StreamFromExclusive pt) >>= \iterator -> do
            followerClose
            atomically $ do
              writeTVar varIterator iterator
              writeTVar varIntersection $ JustNegotiatedIntersection pt
            pure $ Just pt

    pure
      Follower
        { followerInstruction = followerInstructionNonBlocking
        , followerInstructionBlocking
        , followerForward
        , followerClose
        }

  getImmutableTip :: STM m (Tip blk)
  getImmutableTip = maybe TipGenesis tipFromOnDemandTip <$> OnDemand.readOnDemandTip onDemand

blockFetchServer ::
  forall m blk a h.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  BlockFetchEventTracer m blk ->
  OnDemand.OnDemandRuntime m blk h ->
  BlockComponent blk (ChainDB.WithPoint blk a) ->
  ResourceRegistry m ->
  BlockFetchServer a (Point blk) m ()
blockFetchServer tracer onDemand blockComponent _registry =
  blockFetchServer' tracer stream
 where
  stream from to =
    Right . convertIterator
      <$> OnDemand.onDemandIteratorForRange onDemand blockComponent from to

  convertIterator iterator =
    ChainDB.Iterator
      { ChainDB.iteratorNext =
          ImmutableDB.iteratorNext iterator <&> \case
            ImmutableDB.IteratorResult b -> ChainDB.IteratorResult b
            ImmutableDB.IteratorExhausted -> ChainDB.IteratorExhausted
      , ChainDB.iteratorClose = ImmutableDB.iteratorClose iterator
      }

sleepForever :: IOLike m => m a
sleepForever = atomically retry

data ImmDBServerException
  = ReachedImmutableTip
  | TriedToFetchGenesis
  deriving stock Show
  deriving anyclass Exception

tipFromOnDemandTip :: OnDemand.OnDemandTip blk -> Tip blk
tipFromOnDemandTip tip =
  Tip (OnDemand.odtSlot tip) (OnDemand.odtHash tip) (OnDemand.odtBlockNo tip)
