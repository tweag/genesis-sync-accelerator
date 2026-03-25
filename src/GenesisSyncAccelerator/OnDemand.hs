{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

-- | On-demand fetching for ImmutableDB chunk files.
--
-- This module provides streaming helpers that download missing chunks from a CDN
-- and serve them using local iterators that read directly from downloaded files.
module GenesisSyncAccelerator.OnDemand
  ( OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandTip (..)
  , OnDemandState (..)
  , deleteChunkFiles
  , newOnDemandRuntime
  , onDemandIteratorForRange
  , onDemandIteratorFrom
  , readOnDemandTip
  , refreshTip
  ) where

import Control.Concurrent.Async (Async, async, cancelMany, poll, waitCatch)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, putMVar, takeMVar)
import Control.Monad (unless, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (traverse_)
import Data.List (delete, foldl', genericSplitAt, genericTake, partition)
import qualified Data.List.NonEmpty as NEL
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Generics (Generic)
import qualified GenesisSyncAccelerator.RemoteStorage as Remote
import GenesisSyncAccelerator.Types (MaxCachedChunksCount (..), PrefetchChunksCount (..))
import qualified Network.HTTP.Client as HTTP
import Ouroboros.Consensus.Block
  ( BlockNo (..)
  , CodecConfig
  , ConvertRawHash (..)
  , HasHeader
  , Header
  , HeaderHash
  , IsEBB (..)
  , NestedCtxt
  , Point (BlockPoint, GenesisPoint)
  , RealPoint (..)
  , SlotNo (..)
  , StandardHash
  , WithOrigin (..)
  , pointSlot
  , realPointSlot
  )
import Ouroboros.Consensus.Storage.Common
  ( BlockComponent
  , StreamFrom (..)
  , StreamTo (..)
  )
import Ouroboros.Consensus.Storage.ImmutableDB.API
  ( Iterator (..)
  , IteratorResult (..)
  )
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkInfo, ChunkNo (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Layout as ChunkLayout
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Primary as Primary
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
  , STM
  , SomeException
  , StrictTVar
  , atomically
  , bracketOnError
  , newTVarIO
  , onException
  , readTVar
  , readTVarIO
  , swapTVar
  , try
  )
import Ouroboros.Consensus.Util.NormalForm.StrictTVar (writeTVar)
import System.FS.API
  ( Handle
  , HasFS
  , OpenMode (ReadMode)
  , hClose
  , hGetSize
  , hOpen
  , removeFile
  , withFile
  )

-- | Configuration for on-demand fetching.
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
  , odcMaxCachedChunks :: MaxCachedChunksCount
  -- ^ Maximum number of chunks to keep in cache.
  , odcPrefetchAhead :: PrefetchChunksCount
  -- ^ Number of chunks to prefetch ahead of current position.
  }

-- | Combined state for in-flight downloads and pin counts.
data PrefetchJobs = PrefetchJobs
  { pjDownloads :: !(Map.Map ChunkNo (Async (Either Remote.TraceDownloadFailure [FilePath])))
  -- ^ In-flight download jobs, keyed by chunk number.
  , pjPinnedChunks :: !(Map.Map ChunkNo Int)
  -- ^ Reference-counted pinned chunks, protected from LRU eviction.
  }

-- | Shared state for coordinating prefetch downloads across iterators.
newtype PrefetchState = PrefetchState {psJobs :: MVar PrefetchJobs}

data OnDemandRuntime m blk h = OnDemandRuntime
  { odrConfig :: OnDemandConfig m blk h
  , odrManager :: HTTP.Manager
  , odrState :: StrictTVar m (OnDemandState blk)
  , odrPrefetch :: PrefetchState
  }

-- | Initializes the on-demand runtime by fetching the current tip from the remote storage.
newOnDemandRuntime ::
  forall blk m h.
  (IOLike m, MonadIO m, StandardHash blk, ConvertRawHash blk) =>
  OnDemandConfig m blk h ->
  m (OnDemandRuntime m blk h)
newOnDemandRuntime cfg@OnDemandConfig{odcRemote, odcTracer} = do
  env <- liftIO $ Remote.newRemoteStorageEnv (Remote.rscSrcUrl odcRemote) (Remote.rscDstDir odcRemote)
  mbTip <- liftIO $ tipFromRemoteEnv odcTracer env
  stateVar <- newTVarIO (OnDemandState Set.empty [] mbTip)
  prefetch <- liftIO $ PrefetchState <$> newMVar (PrefetchJobs Map.empty Map.empty)
  pure $ OnDemandRuntime cfg (Remote.rseManager env) stateVar prefetch

-- | Internal state tracking which chunks have been downloaded during the current session.
data OnDemandState blk = OnDemandState
  { odsCachedChunks :: Set ChunkNo
  -- ^ Set of chunk indices already present on disk.
  , odsUsageOrder :: [ChunkNo]
  -- ^ Ordered list of chunks in cache, from Most Recently Used to Least Recently Used.
  , odsTip :: Maybe (OnDemandTip blk)
  -- ^ Tip from on-demand data or remote metadata.
  }
  deriving Generic

data OnDemandTip blk = OnDemandTip
  { odtSlot :: SlotNo
  , odtHash :: HeaderHash blk
  , odtBlockNo :: BlockNo
  }
  deriving Generic

deriving instance Eq (HeaderHash blk) => Eq (OnDemandTip blk)

deriving instance Show (HeaderHash blk) => Show (OnDemandTip blk)

deriving instance NoThunks (HeaderHash blk) => NoThunks (OnDemandTip blk)

deriving instance NoThunks (HeaderHash blk) => NoThunks (OnDemandState blk)

onDemandIteratorForRange ::
  forall m blk h b.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  OnDemandRuntime m blk h ->
  BlockComponent blk b ->
  StreamFrom blk ->
  StreamTo blk ->
  m (Iterator m blk b)
onDemandIteratorForRange odr@OnDemandRuntime{odrConfig = OnDemandConfig{odcChunkInfo}} component from to =
  mkOnDemandIterator odr component from (Just to) (getChunksInRange odcChunkInfo from to)

onDemandIteratorFrom ::
  forall m blk h b.
  ( IOLike m
  , MonadIO m
  , HasHeader blk
  , DecodeDisk blk (ByteString -> blk)
  , DecodeDiskDep (NestedCtxt Header) blk
  , ReconstructNestedCtxt Header blk
  , ConvertRawHash blk
  ) =>
  OnDemandRuntime m blk h ->
  BlockComponent blk b ->
  StreamFrom blk ->
  m (Iterator m blk b)
onDemandIteratorFrom odr@OnDemandRuntime{odrConfig = OnDemandConfig{odcChunkInfo}} component from =
  mkOnDemandIterator odr component from Nothing (chunksFrom odcChunkInfo from)

readOnDemandTip :: IOLike m => OnDemandRuntime m blk h -> STM m (Maybe (OnDemandTip blk))
readOnDemandTip OnDemandRuntime{odrState} = odsTip <$> readTVar odrState

-- | Re-fetch the tip from the CDN and update the on-demand state.
-- Failures are silently ignored (already traced by 'fetchTipInfo').
refreshTip ::
  forall blk m h.
  (IOLike m, MonadIO m, ConvertRawHash blk) =>
  OnDemandRuntime m blk h ->
  m ()
refreshTip odr@OnDemandRuntime{odrConfig = OnDemandConfig{odcTracer}, odrState} = do
  mbTip <- liftIO $ tipFromRemoteEnv odcTracer $ getRemoteStorageEnv odr
  case mbTip of
    Nothing -> pure ()
    _ -> atomically $ readTVar odrState >>= \st -> writeTVar odrState st{odsTip = mbTip}

-- | Creates an iterator that downloads and serves chunks one by one,
-- with background prefetching of upcoming chunks.
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
  OnDemandRuntime m blk h ->
  BlockComponent blk b ->
  StreamFrom blk ->
  Maybe (StreamTo blk) ->
  NEL.NonEmpty ChunkNo ->
  m (Iterator m blk b)
mkOnDemandIterator
  odr@OnDemandRuntime
    { odrConfig =
      cfg@OnDemandConfig
        { odcHasFS
        , odcChunkInfo
        , odcCodecConfig
        , odcCheckIntegrity
        , odcTracer
        , odcPrefetchAhead = PrefetchChunksCount numPrefetch
        }
    , odrState
    , odrPrefetch
    }
  component
  from
  to
  chunks = do
    varChunks <- newTVarIO $ NEL.toList chunks
    varCurrentIt <- newTVarIO Nothing
    {-
     Track the current prefetch window in a TVar so that chunks can get unpinned:
     - when the iterator moves forward
     - or when the iterator is closed (e.g. on exception)
    -}
    varPrefetchWindow <- newTVarIO []

    let
      remoteEnv = getRemoteStorageEnv odr
      decPin n = if n <= 1 then Nothing else Just (n - 1)

      updatePrefetchWindow newWindow = do
        oldWindow <- atomically $ swapTVar varPrefetchWindow newWindow
        liftIO
          ( modifyMVar_ (psJobs odrPrefetch) $ \pj ->
              let unpinned = foldl' (flip (Map.update decPin)) (pjPinnedChunks pj) oldWindow
                  pinned = foldl' (\m c -> Map.insertWith (+) c 1 m) unpinned newWindow
               in return pj{pjPinnedChunks = pinned}
          )
          `onException` atomically (writeTVar varPrefetchWindow oldWindow)

      -- Ensure a chunk is available on disk. Returns True if ready, False on failure.
      ensureChunkAvailable c = do
        cached <- odsCachedChunks <$> readTVarIO odrState
        if Set.member c cached
          then return True
          else do
            result <- liftIO $ awaitDownload odcTracer remoteEnv odrPrefetch c
            case result of
              Left _ -> return False
              Right _ -> do
                registerInCache cfg odrPrefetch odrState c
                return True

      -- Clean up iterator prefetch state on exception or failure.
      -- Cleanup consists of unpinning any chunks in the current prefetch window,
      -- allowing them to be evicted if needed.
      cleanupOnError = do
        window <- atomically $ swapTVar varPrefetchWindow []
        jobsToCancel <- liftIO $ modifyMVar (psJobs odrPrefetch) $ \pj ->
          let unpinned = foldl' (flip (Map.update decPin)) (pjPinnedChunks pj) window
              -- Collect download jobs for chunks that are no longer pinned
              (removedJobs, remainingDownloads) =
                foldl'
                  ( \(canceled, dls) c ->
                      case Map.lookup c unpinned of
                        Nothing ->
                          -- Chunk fully unpinned (not expected by another iterator)
                          -- Download job can be safely canceled.
                          case Map.lookup c dls of
                            Just job -> (job : canceled, Map.delete c dls)
                            Nothing -> (canceled, dls)
                        Just _ -> (canceled, dls) -- still pinned by another iterator
                  )
                  ([], pjDownloads pj)
                  window
           in return (pj{pjPinnedChunks = unpinned, pjDownloads = remainingDownloads}, removedJobs)
        liftIO $ cancelMany jobsToCancel

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
                flip onException cleanupOnError $ do
                  -- Compute and set new active prefetch window.
                  let newWindow = c : genericTake numPrefetch rest
                  updatePrefetchWindow newWindow

                  -- Start background prefetches for uncached chunks in the window
                  cached <- odsCachedChunks <$> readTVarIO odrState
                  case NEL.nonEmpty $ filter (`Set.notMember` cached) newWindow of
                    Nothing -> pure ()
                    Just uncached -> liftIO $ prefetchChunks odcTracer remoteEnv odrPrefetch uncached

                  ok <- ensureChunkAvailable c
                  if not ok
                    then do
                      cleanupOnError
                      return IteratorExhausted
                    else do
                      it <-
                        mkRawBlockIterator
                          odcHasFS
                          odcChunkInfo
                          odcCodecConfig
                          odcCheckIntegrity
                          component
                          from
                          to
                          c
                      atomically $ writeTVar varCurrentIt (Just it)
                      next -- Transition to next chunk
      hasNext = readTVar varCurrentIt >>= maybe (return Nothing) iteratorHasNext

      close = do
        readTVarIO varCurrentIt >>= traverse_ iteratorClose
        -- Clean up: unpin the tracked prefetch window.
        cleanupOnError

    return Iterator{iteratorNext = next, iteratorHasNext = hasNext, iteratorClose = close}

-- | Atomically start a download for a chunk, or return an existing in-flight job.
startDownload ::
  Remote.RemoteStorageTracer IO ->
  Remote.RemoteStorageEnv ->
  PrefetchState ->
  ChunkNo ->
  IO (Async (Either Remote.TraceDownloadFailure [FilePath]))
startDownload tracer env PrefetchState{psJobs} chunk =
  modifyMVar psJobs $ \pj ->
    case Map.lookup chunk (pjDownloads pj) of
      Just existingJob ->
        poll existingJob >>= \case
          Nothing ->
            -- Still running
            return (pj, existingJob)
          Just (Right (Right _)) ->
            -- Completed successfully
            return (pj, existingJob)
          Just _ -> do
            -- Failed (exception or TraceDownloadFailure); retry
            job <- async $ Remote.downloadChunk tracer env chunk
            return (pj{pjDownloads = Map.insert chunk job (pjDownloads pj)}, job)
      Nothing -> do
        job <- async $ Remote.downloadChunk tracer env chunk
        return (pj{pjDownloads = Map.insert chunk job (pjDownloads pj)}, job)

-- | Start a download (idempotent), wait for it, then remove from the job map.
awaitDownload ::
  Remote.RemoteStorageTracer IO ->
  Remote.RemoteStorageEnv ->
  PrefetchState ->
  ChunkNo ->
  IO (Either Remote.TraceDownloadFailure [FilePath])
awaitDownload tracer env ps@PrefetchState{psJobs} chunk = do
  job <- startDownload tracer env ps chunk
  let cleanup =
        modifyMVar_ psJobs $ \pj ->
          return
            pj{pjDownloads = Map.update (\j -> if j == job then Nothing else Just j) chunk (pjDownloads pj)}
  outcome <- waitCatch job `onException` cleanup
  cleanup
  return $ either (Left . Remote.TraceDownloadException ("chunk " <> show chunk) . show) id outcome

-- | Fire-and-forget background downloads for the given chunks.
prefetchChunks ::
  Remote.RemoteStorageTracer IO ->
  Remote.RemoteStorageEnv ->
  PrefetchState ->
  NEL.NonEmpty ChunkNo ->
  IO ()
prefetchChunks tracer env ps =
  mapM_ (startDownload tracer env ps)

-- | Register a downloaded chunk in the LRU cache, evicting unpinned excess chunks.
registerInCache ::
  forall m blk h.
  (IOLike m, MonadIO m) =>
  OnDemandConfig m blk h ->
  PrefetchState ->
  StrictTVar m (OnDemandState blk) ->
  ChunkNo ->
  m ()
registerInCache OnDemandConfig{odcHasFS, odcMaxCachedChunks = MaxCachedChunksCount numChunks} PrefetchState{psJobs} stateVar chunk = do
  pj <- liftIO $ takeMVar psJobs
  ( do
      toPrune <- atomically $ do
        let pinned = pjPinnedChunks pj
        curr <- readTVar stateVar
        let
          newUsage = chunk : delete chunk (odsUsageOrder curr)
          newCached = Set.insert chunk (odsCachedChunks curr)
          -- Split into chunks to keep vs candidates for eviction
          (stay, candidates) = genericSplitAt numChunks newUsage
          -- Only evict unpinned chunks
          (keepPinned, prune) = partition (`Map.member` pinned) candidates
          finalUsage = stay ++ keepPinned
          updatedCached = Set.difference newCached (Set.fromList prune)
        writeTVar stateVar curr{odsCachedChunks = updatedCached, odsUsageOrder = finalUsage}
        return prune
      unless (null toPrune) $ mapM_ (deleteChunkFiles odcHasFS) toPrune
      liftIO $ putMVar psJobs pj
    )
    `onException` liftIO (putMVar psJobs pj)

-- | Deletes the triad of files associated with a chunk.
deleteChunkFiles :: IOLike m => HasFS m h -> ChunkNo -> m ()
deleteChunkFiles hasFS chunk = do
  hRemove hasFS (fsPathChunkFile chunk)
  hRemove hasFS (fsPathPrimaryIndexFile chunk)
  hRemove hasFS (fsPathSecondaryIndexFile chunk)
 where
  hRemove h f = void $ try @_ @SomeException $ removeFile h f

-- | Identifies the set of chunks covering a given streaming range.
getChunksInRange :: ChunkInfo -> StreamFrom blk -> StreamTo blk -> NEL.NonEmpty ChunkNo
getChunksInRange chunkInfo from to =
  let startChunk = chunkForFrom chunkInfo from
      endChunk = chunkForTo chunkInfo to
   in chunksBetween startChunk endChunk
 where
  chunksBetween (ChunkNo a) (ChunkNo b) =
    let (lo, hi) = if b < a then (b, a) else (a, b)
     in fmap ChunkNo $ lo NEL.:| [lo + 1 .. hi]

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
mkRawBlockIterator ::
  forall m blk b h.
  ( IOLike m
  , MonadIO m
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
  -- | Stream lower bound: entries at or after this point are streamed.
  -- Note that inclusivity depends on the constructor being used (StreamFromInclusive vs StreamFromExclusive).
  StreamFrom blk ->
  -- | Stream upper bound (always inclusive): entries up to and including this point are streamed.
  Maybe (StreamTo blk) ->
  -- | The chunk from which to read blocks.
  ChunkNo ->
  m (Iterator m blk b)
mkRawBlockIterator hasFS chunkInfo codecConfig checkIntegrity component from to chunk = do
  -- 1. Read all entries from the requested chunks.
  allEntries <- do
    chunkSize <- withFile hasFS (fsPathChunkFile chunk) ReadMode (hGetSize hasFS)
    -- Determine per-chunk whether the first entry is an EBB by reading
    -- the primary index, rather than assuming all chunks start with EBBs.
    mbFirstSlot <- Primary.readFirstFilledSlot (Proxy @blk) hasFS chunkInfo chunk
    let firstIsEBB = maybe IsNotEBB ChunkLayout.relativeSlotIsEBB mbFirstSlot
    Secondary.readAllEntries hasFS 0 chunk (const False) chunkSize firstIsEBB

  let flatEntries =
        maybe id (applyStreamTo chunkInfo) to
          . applyStreamFrom chunkInfo from
          $ allEntries
  varEntries <- newTVarIO flatEntries
  varHandle <- newTVarIO (Nothing :: Maybe (Handle h))

  -- 2. Define the 'iteratorNext' action.
  -- This action pops the next entry from the queue, opens the corresponding chunk file,
  -- reads the block data, and extracts the requested component.
  -- Since this iterator always serves a single chunk, the handle is opened once on the
  -- first call and reused for all subsequent blocks.
  let next =
        readTVarIO varEntries >>= \case
          [] -> return IteratorExhausted
          ((WithBlockSize size entry) : rest) -> do
            atomically $ writeTVar varEntries rest

            handle <-
              readTVarIO varHandle >>= \case
                Just h -> pure h
                Nothing ->
                  bracketOnError
                    (hOpen hasFS (fsPathChunkFile chunk) ReadMode)
                    closeHandle
                    (\h -> h <$ atomically (writeTVar varHandle (Just h)))

            res <-
              onException
                ( extractBlockComponent
                    hasFS
                    chunkInfo
                    chunk
                    codecConfig
                    checkIntegrity
                    handle
                    (WithBlockSize size entry)
                    component
                )
                ( do
                    atomically $ writeTVar varHandle Nothing
                    closeHandle handle
                )
            return $ IteratorResult res

      -- 3. Define the 'iteratorHasNext' action.
      -- Peeks at the next entry in the queue to return its Point.
      hasNext =
        readTVar varEntries >>= \case
          [] -> return Nothing
          ((WithBlockSize _ entry) : _) ->
            return $ Just (tipToRealPoint chunkInfo entry)

      -- 4. Define the 'iteratorClose' action.
      close =
        readTVarIO varHandle >>= \case
          Nothing -> pure ()
          Just handle -> closeHandle handle

  return Iterator{iteratorNext = next, iteratorHasNext = hasNext, iteratorClose = close}
 where
  -- \| Reusable function to close the given handle
  closeHandle :: Handle h -> m ()
  closeHandle = hClose hasFS

-- | Helper to convert an Index 'Entry' (which stores hash and slot/epoch)
-- into a 'RealPoint' (which uses SlotNo).
tipToRealPoint :: ChunkInfo -> Entry blk -> RealPoint blk
tipToRealPoint ci Secondary.Entry{blockOrEBB, headerHash} =
  RealPoint (ChunkLayout.slotNoOfBlockOrEBB ci blockOrEBB) headerHash

chunksFrom :: ChunkInfo -> StreamFrom blk -> NEL.NonEmpty ChunkNo
chunksFrom ci from = NEL.iterate nextChunk (chunkForFrom ci from)
 where
  nextChunk (ChunkNo n) = ChunkNo (n + 1)

-- | Filter entries to honour the 'StreamFrom' lower bound.
--
-- For 'StreamFromExclusive pt', drops entries at or before @pt@.
-- For 'StreamFromInclusive pt', drops entries strictly before @pt@.
-- Entries within a chunk are ordered (EBB first, then regular blocks by slot),
-- so a simple 'dropWhile' from the front suffices.
applyStreamFrom ::
  Eq (HeaderHash blk) =>
  ChunkInfo ->
  StreamFrom blk ->
  [WithBlockSize (Entry blk)] ->
  [WithBlockSize (Entry blk)]
applyStreamFrom ci = \case
  StreamFromExclusive GenesisPoint -> id
  StreamFromExclusive (BlockPoint fromSlot fromHash) ->
    dropWhile $ \(WithBlockSize _ e) ->
      let eSlot = ChunkLayout.slotNoOfBlockOrEBB ci (blockOrEBB e)
       in eSlot < fromSlot || (eSlot == fromSlot && headerHash e == fromHash)
  StreamFromInclusive (RealPoint fromSlot fromHash) ->
    dropWhile $ \(WithBlockSize _ e) ->
      let eSlot = ChunkLayout.slotNoOfBlockOrEBB ci (blockOrEBB e)
       in eSlot < fromSlot || (eSlot == fromSlot && headerHash e /= fromHash)

-- | Filter entries to honour the 'StreamTo' upper bound.
--
-- For 'StreamToInclusive pt', takes entries up to and including @pt@.
-- Entries within a chunk are ordered (EBB first, then regular blocks by slot),
-- so a simple 'takeWhile' from the front suffices.
applyStreamTo ::
  ChunkInfo ->
  StreamTo blk ->
  [WithBlockSize (Entry blk)] ->
  [WithBlockSize (Entry blk)]
applyStreamTo ci (StreamToInclusive (RealPoint toSlot _toHash)) =
  takeWhile $ \(WithBlockSize _ e) ->
    ChunkLayout.slotNoOfBlockOrEBB ci (blockOrEBB e) <= toSlot

tipFromRemoteEnv ::
  forall blk.
  ConvertRawHash blk =>
  Remote.RemoteStorageTracer IO ->
  Remote.RemoteStorageEnv ->
  IO (Maybe (OnDemandTip blk))
tipFromRemoteEnv tr env = either (const Nothing) (Just . tipFromRemoteInfo) <$> Remote.fetchTipInfo tr env

tipFromRemoteInfo :: forall blk. ConvertRawHash blk => Remote.RemoteTipInfo -> OnDemandTip blk
tipFromRemoteInfo info =
  OnDemandTip
    { odtSlot = SlotNo (Remote.rtiSlot info)
    , odtHash = fromRawHash (Proxy @blk) (Remote.rtiHashBytes info)
    , odtBlockNo = BlockNo (Remote.rtiBlockNo info)
    }

getRemoteStorageEnv :: OnDemandRuntime m blk h -> Remote.RemoteStorageEnv
getRemoteStorageEnv OnDemandRuntime{odrManager, odrConfig = OnDemandConfig{odcRemote}} =
  Remote.RemoteStorageEnv{Remote.rseManager = odrManager, Remote.rseConfig = odcRemote}
