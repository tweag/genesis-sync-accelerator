{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- | On-demand fetching wrapper for ImmutableDB.
--
-- This module provides a decorator for 'ImmutableDB' that intercepts streaming
-- requests. If the requested data is beyond the current indexed tip, it downloads
-- the missing chunks from a CDN and serves them using a local iterator that
-- reads directly from the downloaded chunk files.
module GenesisSyncAccelerator.OnDemand
  ( decorateImmutableDB
  , OnDemandConfig (..)
  ) where

import Control.Monad (forM, unless, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.List (delete)
import Data.Proxy (Proxy (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Debug.Trace (trace)
import GHC.Generics (Generic)
import qualified GenesisSyncAccelerator.RemoteStorage as Remote
import Ouroboros.Consensus.Block
  ( BlockNo (..)
  , CodecConfig
  , ConvertRawHash (..)
  , HasHeader
  , Header
  , IsEBB (..)
  , NestedCtxt
  , RealPoint (..)
  , SlotNo (..)
  , WithOrigin (..)
  , pointSlot
  , realPointSlot
  )
import Ouroboros.Consensus.Block.RealPoint (realPointToPoint)
import Ouroboros.Consensus.Storage.Common (BlockComponent, StreamFrom (..), StreamTo (..))
import Ouroboros.Consensus.Storage.ImmutableDB.API
  ( ImmutableDB (..)
  , Iterator (..)
  , IteratorResult (..)
  , Tip (..)
  , getTipPoint
  )
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkInfo, ChunkNo (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal as ChunkInfo
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Layout as ChunkLayout
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Secondary (Entry (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Secondary as Secondary
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Iterator (extractBlockComponent)
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Types (WithBlockSize (..))
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Util
  ( fsPathChunkFile
  , fsPathPrimaryIndexFile
  , fsPathSecondaryIndexFile
  )
import Ouroboros.Consensus.Storage.Serialisation
import Ouroboros.Consensus.Util.IOLike
  ( IOLike
  , NoThunks
  , SomeException
  , StrictTVar
  , atomically
  , newTVarIO
  , readTVar
  , readTVarIO
  , try
  )
import Ouroboros.Consensus.Util.NormalForm.StrictTVar (writeTVar)
import System.FS.API (HasFS, OpenMode (ReadMode), hGetSize, removeFile, withFile)

-- | Configuration for the On-Demand decorator.
data OnDemandConfig m blk h = OnDemandConfig
  { odcRemote :: Remote.RemoteStorageConfig
  -- ^ CDN connection details.
  , odcTracer :: Remote.RemoteStorageTracer IO
  -- ^ Tracer for remote storage events.
  , odcChunkInfo :: ChunkInfo
  -- ^ Information about chunk sizes used for slot-to-chunk translation.
  , odcHasFS :: HasFS m h
  -- ^ File system handle for saving downloaded chunks.
  , odcCodecConfig :: CodecConfig blk
  -- ^ Codec configuration for block extraction.
  , odcCheckIntegrity :: blk -> Bool
  -- ^ Integrity check for extracted blocks.
  , odcMaxCachedChunks :: Int
  -- ^ Maximum number of chunks to keep in cache.
  }

-- | Internal state tracking which chunks have been downloaded during the current session.
data OnDemandState = OnDemandState
  { odsCachedChunks :: Set ChunkNo
  -- ^ Set of chunk indices already present on disk.
  , odsUsageOrder :: [ChunkNo]
  -- ^ Ordered list of chunks in cache, from Most Recently Used to Least Recently Used.
  }
  deriving (Generic, NoThunks)

-- | Wraps an existing 'ImmutableDB' with on-demand fetching logic.
--
-- The resulting database will behave exactly like the original, except that
-- 'stream_' calls reaching beyond the current local tip will trigger HTTP
-- downloads of the required chunks.
decorateImmutableDB ::
  forall m blk h.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  OnDemandConfig m blk h ->
  ImmutableDB m blk ->
  m (ImmutableDB m blk)
decorateImmutableDB cfg@OnDemandConfig{odcChunkInfo} db = do
  stateVar <- newTVarIO (OnDemandState Set.empty [])
  pure $
    db
      { getTip_ =
          -- Return a fake tip far in the future to allow streamAfterPoint to proceed.
          -- ChainSync uses the tip to decide whether to stream blocks.
          let dummyHash = fromRawHash (Proxy @blk) (LBS.toStrict (LBS.replicate (fromIntegral (hashSize (Proxy @blk))) 0))
           in return . NotOrigin $ Tip maxBound IsNotEBB maxBound dummyHash
      , stream_ = \registry component from to -> do
          let requestedChunks = getChunksInRange odcChunkInfo from to

          -- Check if ImmutableDB already has this range
          tipPoint <- atomically $ getTipPoint db

          let StreamToInclusive rp = to
          let toPoint = realPointToPoint rp

          -- Logic: If we are syncing beyond the current local tip, use Lazy On-Demand Iterator
          if tipPoint >= toPoint
            then stream_ db registry component from to
            else
              Right
                <$> mkOnDemandIterator
                  cfg
                  stateVar
                  component
                  requestedChunks
      }

-- | Creates an iterator that downloads and serves chunks one by one.
mkOnDemandIterator ::
  forall m blk h b.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  OnDemandConfig m blk h ->
  StrictTVar m OnDemandState ->
  BlockComponent blk b ->
  [ChunkNo] ->
  m (Iterator m blk b)
mkOnDemandIterator cfg@OnDemandConfig{odcHasFS, odcChunkInfo, odcCodecConfig, odcCheckIntegrity} stateVar component chunks = do
  varChunks <- newTVarIO chunks
  varCurrentIt <- newTVarIO Nothing

  let
    next = do
      current <- readTVarIO varCurrentIt
      case current of
        Just it -> do
          res <- iteratorNext it
          case res of
            IteratorResult b -> return (IteratorResult b)
            IteratorExhausted -> do
              iteratorClose it
              atomically $ writeTVar varCurrentIt Nothing
              next -- Transition to next chunk
        Nothing -> do
          cs <- readTVarIO varChunks
          case cs of
            [] -> return IteratorExhausted
            (c : rest) -> do
              atomically $ writeTVar varChunks rest
              -- Download only the current chunk before serving it
              ensureChunks cfg stateVar [c]
              it <-
                mkRawChunkIterator
                  odcHasFS
                  odcChunkInfo
                  odcCodecConfig
                  odcCheckIntegrity
                  component
                  [c]
              atomically $ writeTVar varCurrentIt (Just it)
              next -- Transition to next chunk
    hasNext =
      readTVar varCurrentIt >>= \case
        Just it -> iteratorHasNext it
        Nothing -> return Nothing

    close =
      readTVarIO varCurrentIt >>= \case
        Just it -> iteratorClose it
        Nothing -> return ()

  return Iterator{iteratorNext = next, iteratorHasNext = hasNext, iteratorClose = close}

-- | Ensures that the requested chunks are present on disk, downloading them if necessary.
-- Implements an LRU eviction policy to maintain the 'odcMaxCachedChunks' limit.
ensureChunks ::
  forall m blk h.
  (IOLike m, MonadIO m) =>
  OnDemandConfig m blk h ->
  StrictTVar m OnDemandState ->
  [ChunkNo] ->
  m ()
ensureChunks OnDemandConfig{odcRemote, odcTracer, odcHasFS, odcMaxCachedChunks} stateVar requestedChunks = do
  -- 1. Identify and download missing chunks
  state <- readTVarIO stateVar
  let missingChunks = filter (\c -> not (Set.member c (odsCachedChunks state))) requestedChunks

  unless (null missingChunks) $ do
    liftIO $ mapM_ (Remote.downloadChunk odcTracer odcRemote) missingChunks

  -- 2. Update usage order and identify chunks to prune
  toPrune <- atomically $ do
    curr <- readTVar stateVar
    let
      -- Move requested chunks to the head (most recently used)
      newUsage = requestedChunks ++ foldr delete (odsUsageOrder curr) requestedChunks
      newCached = Set.union (odsCachedChunks curr) (Set.fromList requestedChunks)

      -- Eviction: if we exceed the limit, prune the least recently used chunks.
      -- We must keep all chunks currently requested to ensure iterator safety.
      (stay, prune) = splitAt (max odcMaxCachedChunks (length requestedChunks)) newUsage
      updatedCached = Set.difference newCached (Set.fromList prune)

    writeTVar stateVar (OnDemandState updatedCached stay)
    return prune

  -- 3. Physically delete pruned chunks from disk
  unless (null toPrune) $
    mapM_ (deleteChunkFiles odcHasFS) toPrune

-- | Deletes the triad of files associated with a chunk.
deleteChunkFiles :: IOLike m => HasFS m h -> ChunkNo -> m ()
deleteChunkFiles hasFS chunk = do
  hRemove hasFS (fsPathChunkFile chunk)
  hRemove hasFS (fsPathPrimaryIndexFile chunk)
  hRemove hasFS (fsPathSecondaryIndexFile chunk)
 where
  hRemove h f = void $ try @_ @SomeException $ removeFile h f

-- | Identifies the set of chunks covering a given streaming range.
getChunksInRange :: ChunkInfo -> StreamFrom blk -> StreamTo blk -> [ChunkNo]
getChunksInRange chunkInfo from to =
  let startChunk = chunkForFrom chunkInfo from
      endChunk = chunkForTo chunkInfo to
   in ChunkInfo.chunksBetween startChunk endChunk

-- | Translates a 'StreamFrom' bound to its starting 'ChunkNo'.
chunkForFrom :: ChunkInfo -> StreamFrom blk -> ChunkNo
chunkForFrom ci (StreamFromInclusive pt) = ChunkLayout.chunkIndexOfSlot ci (realPointSlot pt)
chunkForFrom ci (StreamFromExclusive pt) = case pointSlot pt of
  Origin -> ChunkNo 0
  NotOrigin slot -> ChunkLayout.chunkIndexOfSlot ci slot

-- | Translates a 'StreamTo' bound to its ending 'ChunkNo'.
chunkForTo :: ChunkInfo -> StreamTo blk -> ChunkNo
chunkForTo ci (StreamToInclusive pt) = ChunkLayout.chunkIndexOfSlot ci (realPointSlot pt)

-- | Creates a "Raw Chunk Iterator" that serves blocks from a specific list of chunks.
--
-- This iterator is "stateless" in the sense that it does not rely on the global
-- 'ImmutableDB' state (tip, indices, etc.). Instead, it directly parses the
-- secondary index files on disk to find the requested blocks.
mkRawChunkIterator ::
  forall m blk b h.
  ( IOLike m
  , HasHeader blk
  , DecodeDisk blk (LBS.ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  HasFS m h ->
  ChunkInfo ->
  CodecConfig blk ->
  -- | Integrity check function to validate blocks read from disk.
  (blk -> Bool) ->
  -- | The component of the block to stream (e.g., the whole block, just the header, etc.).
  BlockComponent blk b ->
  -- | The list of chunks (epochs) to iterate over.
  [ChunkNo] ->
  m (Iterator m blk b)
mkRawChunkIterator hasFS chunkInfo codecConfig checkIntegrity component chunks = do
  -- 1. Read all entries from all requested chunks.
  -- We map over the chunks, open the corresponding secondary index file, and parse all entries.
  allEntries <- forM chunks $ \chunk -> do
    chunkSize <- withFile hasFS (fsPathChunkFile chunk) ReadMode (hGetSize hasFS)
    -- We assume the first block might be an EBB if the chunk supports it.
    let firstIsEBB = if ChunkInfo.chunkInfoSupportsEBBs chunkInfo then IsEBB else IsNotEBB
    entries <- Secondary.readAllEntries hasFS 0 chunk (const False) chunkSize firstIsEBB
    return $ map (chunk,) entries

  let flatEntries = concat allEntries
  varEntries <- newTVarIO flatEntries

  -- 2. Define the 'iteratorNext' action.
  -- This action pops the next entry from the queue, opens the corresponding chunk file,
  -- reads the block data, and extracts the requested component.
  let next =
        readTVarIO varEntries >>= \case
          [] -> return IteratorExhausted
          ((chunk, WithBlockSize size entry) : rest) -> do
            atomically $ writeTVar varEntries rest
            -- We open the file for every block. This is inefficient but safe.
            -- Optimization: Keep the file handle open until the chunk changes.
            res <- withFile hasFS (fsPathChunkFile chunk) ReadMode $ \hnd ->
              extractBlockComponent
                hasFS
                chunkInfo
                chunk
                codecConfig
                checkIntegrity
                hnd
                (WithBlockSize size entry)
                component
            return $ IteratorResult res

      -- 3. Define the 'iteratorHasNext' action.
      -- Peeks at the next entry in the queue to return its Point.
      hasNext =
        readTVar varEntries >>= \case
          [] -> return Nothing
          ((_, WithBlockSize _ entry) : _) ->
            return $ Just (tipToRealPoint chunkInfo entry)

      -- 4. Define the 'iteratorClose' action.
      -- Since we don't keep persistent file handles (we open/close per block),
      -- there is nothing to clean up here.
      close = return ()

  return Iterator{iteratorNext = next, iteratorHasNext = hasNext, iteratorClose = close}

-- | Helper to convert an Index 'Entry' (which stores hash and slot/epoch)
-- into a 'RealPoint' (which uses SlotNo).
tipToRealPoint :: ChunkInfo -> Entry blk -> RealPoint blk
tipToRealPoint ci Secondary.Entry{blockOrEBB, headerHash} =
  RealPoint (ChunkLayout.slotNoOfBlockOrEBB ci blockOrEBB) headerHash
