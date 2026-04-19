{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-x-partial #-}

module Test.GenesisSyncAccelerator.OnDemand.Iteration (tests) where

import Cardano.Slotting.Slot (SlotNo (..))
import qualified Codec.CBOR.Write as CBOR
import Codec.Serialise (Serialise (encode))
import Control.Exception (try)
import Control.Monad (forM_, unless, when)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.List as List
import qualified Data.List.NonEmpty as NEL (fromList, init)
import qualified Data.Map as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Conc (atomically)
import GenesisSyncAccelerator.OnDemand
  ( IllegalStreamOperation
  , OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandState (..)
  )
import qualified GenesisSyncAccelerator.OnDemand as OnDemand
import GenesisSyncAccelerator.RemoteStorage (FileType (..), RemoteStorageConfig (..), getFileName)
import GenesisSyncAccelerator.Types
  ( MaxCachedChunksCount (..)
  , PrefetchChunksCount (..)
  , RetryCount (..)
  )
import GenesisSyncAccelerator.Util (fpToHasFS)
import Ouroboros.Consensus.Block (StandardHash)
import Ouroboros.Consensus.Block.Abstract
  ( ConvertRawHash
  , GetHeader (..)
  , Point (GenesisPoint)
  , blockHash
  , blockPoint
  , blockSlot
  )
import Ouroboros.Consensus.Block.RealPoint (blockRealPoint)
import Ouroboros.Consensus.Storage.Common
  ( BinaryBlockInfo (..)
  , BlockComponent (..)
  , StreamFrom (..)
  , StreamTo (..)
  )
import Ouroboros.Consensus.Storage.ImmutableDB.API
  ( Iterator (..)
  , IteratorResult (..)
  , Tip (..)
  , blockToTip
  , tipHash
  )
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks (ChunkInfo (..), ChunkSize (..))
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Layout as ChunkLayout
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Primary as Primary (mk, write)
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Secondary
  ( BlockOffset (..)
  , Entry (..)
  , HeaderOffset (..)
  , HeaderSize (..)
  )
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Secondary as Secondary
  ( writeAllEntries
  )
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Types (BlockOrEBB (..))
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Util (fsPathChunkFile, fsPathPrimaryIndexFile)
import Ouroboros.Consensus.Storage.Serialisation (HasBinaryBlockInfo (..))
import Ouroboros.Consensus.Util.NormalForm.StrictTVar (readTVarIO, writeTVar)
import System.FS.API (AllowExisting (MustBeNew), HasFS, OpenMode (..), withFile)
import System.FS.API.Types (Handle)
import System.FS.CRC (CRC, hPutAllCRC)
import System.FS.IO (HandleIO)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Types (TmpDir (..))
import Test.GenesisSyncAccelerator.Utilities (blockChunk, getLocalUrl, groupBlocksByChunk)
import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import Test.Util.TestBlock
  ( TestBlock
  , TestBlockWith (tbSlot, tbValid)
  , TestHash
  , Validity (..)
  , testHashFromList
  , unsafeTestBlockWithPayload
  )
import qualified Test.Util.TestBlock as TB
import "contra-tracer" Control.Tracer (nullTracer)

-------------------------------------------------------------------------------------------------------------------
-- OnDemand.onDemandIteratorFrom ----------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------

prop_fullIterationOverChainHeadersRecapitulatesInput :: Property
prop_fullIterationOverChainHeadersRecapitulatesInput =
  forAll genBlocksAndChunkInfo $ \(blocks, chunkInfo) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        iter <-
          OnDemand.onDemandIteratorFrom
            runtime
            GetHash
            (StreamFromExclusive GenesisPoint)
        (\hs -> hs === map blockHash blocks) <$> iteratorToList iter

prop_onDemandIteratorFromIsCorrectForStreamFromInclusive :: Property
prop_onDemandIteratorFromIsCorrectForStreamFromInclusive =
  -- Generate blocks and the index of one of them to start from.
  forAll (genBlocksAndChunkInfo >>= (\(bs, ci) -> (bs,ci,) <$> chooseInt (0, length bs - 1))) $ \(blocks, chunkInfo, startIndex) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        iter <-
          OnDemand.onDemandIteratorFrom
            runtime
            GetHash
            (StreamFromInclusive . blockRealPoint $ blocks !! startIndex)
        (\hs -> hs === map blockHash (drop startIndex blocks)) <$> iteratorToList iter

prop_onDemandIteratorFromIsCorrectForStreamFromExclusive :: Property
prop_onDemandIteratorFromIsCorrectForStreamFromExclusive =
  -- Generate blocks and the index of one of them to start from just after (i.e., excluding the block itself).
  forAll (genBlocksAndChunkInfo >>= (\(bs, ci) -> (bs,ci,) <$> chooseInt (0, length bs - 1))) $ \(blocks, chunkInfo, startIndex) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let startPoint = blockPoint (blocks !! startIndex)
        iter <-
          OnDemand.onDemandIteratorFrom
            runtime
            GetHash
            (StreamFromExclusive startPoint)
        (\hs -> hs === map blockHash (drop (startIndex + 1) blocks)) <$> iteratorToList iter

prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockButWithinSameChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockButWithinSameChunk =
  forAll (genBlocksAndChunkInfo `suchThat` uncurry thereIsRoomForOneMoreSlotInFinalChunk) $ \(blocks, chunkInfo) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        -- Start just after the last block, but still within the same chunk, so that the error is about
        -- the stream bound not being found rather than about the chunk not being available at all.
        let afterLastBlock = incrementSlot $ last blocks
            streamBound = StreamFromInclusive $ blockRealPoint afterLastBlock
            expErr = OnDemand.StreamBoundNotFound (blockSlot afterLastBlock, blockHash afterLastBlock) Nothing
        unless (blockChunk chunkInfo afterLastBlock == blockChunk chunkInfo (last blocks)) $
          error
            "Precondition violation: generated block for stream bound is not actually in the same chunk as the last block"
        checkIterWithStreamFromFails runtime (=== expErr) streamBound
 where
  thereIsRoomForOneMoreSlotInFinalChunk blocks ci =
    -- At least one more slot in the final (greatest) chunk is necessary to be the slot for the point from which to start.
    maximum (map blockRawSlot blocks) `mod` numSlotsPerChunk ci < (numSlotsPerChunk ci - 1)

prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk =
  forAll myGen $ \(blocks, chunkInfo, badBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        unless (blockChunk chunkInfo badBlock == blockChunk chunkInfo (head blocks)) $
          error
            "Precondition violation: generated block for stream bound is not actually in the same chunk as the first block"
        unless (blockSlot badBlock < blockSlot (head blocks)) $
          error
            "Precondition violation: generated block for stream bound is not actually before the first block"
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        -- Start is before the first block, but still within the same chunk, so that the error is about
        -- the stream bound not being found rather than about the chunk not being available at all.
        let checkError (OnDemand.StreamBoundNotFound (s, h) _) = conjoin [s === blockSlot badBlock, h === blockHash badBlock]
            checkError e = counterexample ("Expected StreamBoundNotFound error; got: " ++ show e) False
        conjoin
          <$> traverse
            (\buildBound -> checkIterWithStreamFromFails runtime checkError $ buildBound badBlock)
            buildersForStreamFrom
 where
  myGen = do
    -- We need room (a slot) in the chunk for a block (for the stream bound) to place before the first block.
    (bs, ci) <- genBlocksAndChunkInfoWithRoomInMinChunk
    let leastChunk = getMinChunk ci bs
    slot <-
      SlotNo <$> choose (unChunkNo leastChunk * numSlotsPerChunk ci, minimum (map blockRawSlot bs) - 1)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, ci, unsafeTestBlock slot hash valid)

prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk =
  forAll myGen $ \(blocks, chunkInfo, extraBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        unless (blockChunk chunkInfo extraBlock > blockChunk chunkInfo (last blocks)) $
          error
            "Precondition violation: generated block for stream bound is not actually in a later chunk than the last block"
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        -- Start is from after the last (greatest) chunk, so the expected error is about chunk availability.
        let getExpErr = OnDemand.firstChunkNotAvailable chunkInfo
        conjoin
          <$> traverse
            ( \buildBound -> let b = buildBound extraBlock in checkIterWithStreamFromFails runtime (=== getExpErr b) b
            )
            buildersForStreamFrom
 where
  -- Generate the chain of blocks and chunk info, then generate a block beyond the greatest chunk.
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfo
    let greatestChunk = ChunkLayout.chunkIndexOfSlot ci $ maximum $ map blockSlot bs
        firstSlotBeyondLastChunk = (1 + unChunkNo greatestChunk) * numSlotsPerChunk ci
    slot <-
      SlotNo <$> choose (firstSlotBeyondLastChunk, firstSlotBeyondLastChunk + 3 * numSlotsPerChunk ci)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, ci, unsafeTestBlock slot hash valid)

-- The error here should be about the starting point not being found.
prop_onDemandIteratorFromErrorsWhenStartingBetweenSlotNumbersWithinChain :: Property
prop_onDemandIteratorFromErrorsWhenStartingBetweenSlotNumbersWithinChain =
  forAll myGen $ \(blocks, chunkInfo, nonExistentBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        when (blockSlot nonExistentBlock `elem` map blockSlot blocks) $
          error "Precondition violation: generated start block with slot already in use"
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let checkError (OnDemand.StreamBoundNotFound (s, h) _) =
              conjoin
                [ s === blockSlot nonExistentBlock
                , h === blockHash nonExistentBlock
                ]
            checkError e = counterexample ("Expected StreamBoundNotFound error but got different error: " ++ show e) False
        conjoin
          <$> traverse
            (\buildBound -> checkIterWithStreamFromFails runtime checkError (buildBound nonExistentBlock))
            buildersForStreamFrom
 where
  -- Generate slots such that at least one pair of consecutive slots has a gap between them,
  -- and then generate a block (from which to derive the stream bound start) for that slot.
  myGen = do
    let offset xs = zip (drop 1 xs) xs
        getSlots = map blockSlot
        getDiffs = map (uncurry (-)) . offset
    (bs, ci) <- genBlocksAndChunkInfo `suchThat` (\(bs, _) -> any (> 1) (getDiffs $ getSlots bs))
    let slotOptions = concatMap (\(b, a) -> if b - a <= 1 then [] else [(a + 1) .. (b - 1)]) $ offset $ getSlots bs
    case slotOptions of
      -- Need at least 1 from which to call elements
      [] -> do
        error $ "Failed to generate slotOptions; slots: " ++ show (getSlots bs)
      _ -> do
        extraSlot <- elements slotOptions
        extraHash <- arbitrary
        extraValid <- arbitrary
        return (bs, ci, unsafeTestBlock extraSlot extraHash extraValid)

-- Here the stream bound (start) should not be found, on account of having the wrong header hash for the block in that slot.
prop_onDemandIteratorFromErrorsWhenStartingWithSlotNumberOnChainButWrongHeaderHash :: Property
prop_onDemandIteratorFromErrorsWhenStartingWithSlotNumberOnChainButWrongHeaderHash =
  forAll myGen $ \(blocks, chunkInfo, nonExistentBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        case blockHash <$> List.find (\b -> blockSlot b == blockSlot nonExistentBlock) blocks of
          Nothing ->
            error
              "Precondition violation: generated start block with slot number not present among other blocks"
          Just h ->
            when (h == blockHash nonExistentBlock) $
              error
                "Precondition violation: generated start block with used slot but same header hash as already present there"
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let checkError (OnDemand.StreamBoundNotFound (s, h) (Just _)) =
              conjoin
                [ s === blockSlot nonExistentBlock
                , h === blockHash nonExistentBlock
                ]
            checkError e = counterexample ("Expected StreamBoundNotFound error but got different error: " ++ show e) False
        conjoin
          <$> traverse
            (checkIterWithStreamFromFails runtime checkError)
            [ StreamFromExclusive (blockPoint nonExistentBlock)
            , StreamFromInclusive (blockRealPoint nonExistentBlock)
            ]
 where
  -- Generate blocks and then select one from which to derive the stream start point, changing its hash so it's not found.
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfo
    b <- elements bs
    newHash <- arbitrary `suchThat` (/= blockHash b)
    let newBlock = unsafeTestBlock (blockSlot b) newHash (tbValid b)
    return (bs, ci, newBlock)

prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk =
  forAll myGen $ \(blocks, chunkInfo, badBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        unless (blockChunk chunkInfo badBlock < blockChunk chunkInfo (head blocks)) $
          error
            "Precondition violation: generated block for stream bound is not actually in a lower chunk than the first block"
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        -- Start is from before the first (least) chunk, so the expected error is about chunk availability.
        let getExpErr = OnDemand.firstChunkNotAvailable chunkInfo
        conjoin
          <$> traverse
            ( \buildBound -> let b = buildBound badBlock in checkIterWithStreamFromFails runtime (=== getExpErr b) b
            )
            buildersForStreamFrom
 where
  -- Generate the chain of blocks and chunk info, then generate a block before the least chunk.
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfoWithRoomForLowChunk
    let maxSlotRaw = numSlotsPerChunk ci * unChunkNo (getMinChunk ci bs) - 1
    slot <- SlotNo <$> choose (0, maxSlotRaw)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, ci, unsafeTestBlock slot hash valid)

----------------------------------------------------------------------------------------------------------------------
-- OnDemand.onDemandIteratorForRange ---------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------

prop_onDemandIteratorForRangeErrorsCorrectlyWhenStreamBoundHashesMatchAndLowerBoundIsExclusive ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenStreamBoundHashesMatchAndLowerBoundIsExclusive =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        unless (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks do not have the same hash"
        unless (blockSlot blockFrom < blockSlot blockTo) $
          error "Precondition violation: lower bound block is not before upper bound block"
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            lowerBound = StreamFromExclusive (blockPoint blockFrom)
        either
          (checkStreamBoundsError lowerBound upperBound)
          (const $ counterexample "Expected error but got successful result" False)
          <$> try
            (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
 where
  myGen = do
    -- Generate the blocks such that if the lower bound block is in the lowest chunk,
    -- there's still room for the upper bound chunk to be below it (i.e., in the chunk not yet populated).
    (bs, ci) <- genBlocksAndChunkInfoWithRoomForLowChunk `suchThat` ((> 1) . length . fst)
    let getRawChunk = unChunkNo . blockChunk ci
        maxRawChunk = maximum (map getRawChunk bs) + 1 -- Allow going just above the extant chunks if necessary.
        genAtLeastLowerExtant = do
          lowerBlock <- elements bs
          upperBlock <-
            genBlockFromGenSlot $
              SlotNo <$> choose (1 + blockRawSlot lowerBlock, numSlotsPerChunk ci * (maxRawChunk + 1) - 1)
          return (lowerBlock, modifyBlockHash upperBlock (blockHash lowerBlock))
        genAtLeastUpperExtant = do
          upperBlock <- elements bs
          lowerBlock <- genBlockFromGenSlot $ SlotNo <$> choose (0, blockRawSlot upperBlock - 1)
          return (modifyBlockHash lowerBlock (blockHash upperBlock), upperBlock)
        genMaybeNeitherExtant = do
          lowerBlock <-
            genBlockFromGenSlot $ SlotNo <$> choose (0, numSlotsPerChunk ci * (maxRawChunk + 1) - 2)
          upperBlock <-
            genBlockFromGenSlot $
              SlotNo <$> choose (blockRawSlot lowerBlock + 1, numSlotsPerChunk ci * (maxRawChunk + 1) - 1)
          return (lowerBlock, modifyBlockHash upperBlock (blockHash lowerBlock))
    (b', b'') <-
      oneof
        [ genAtLeastLowerExtant
        , genAtLeastUpperExtant
        , genMaybeNeitherExtant
        ]
    return (bs, ci, (b', b''))

prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsAfterUpperBound :: Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsAfterUpperBound =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        unless (blockSlot blockFrom > blockSlot blockTo) $
          error "Precondition violation: generated blockFrom is not actually after blockTo"
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either
                      (checkStreamBoundsError lowerBound upperBound)
                      (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    -- Generate the blocks such that if the lower bound block is in the lowest chunk,
    -- there's still room for the upper bound chunk to be below it (i.e., in the chunk not yet populated).
    (bs, ci) <- genBlocksAndChunkInfoWithRoomForLowChunk `suchThat` ((> 1) . length . fst)
    let getRawChunk = unChunkNo . blockChunk ci
        maxRawChunk = maximum (map getRawChunk bs) + 1 -- Allow going just above the extant chunks if necessary.
        -- For each generator, ignore the slot order of the generated blocks; ensure just that one is
        -- greater than the other. Take care of the order in the last step, swapping the blocks as necessary.
        genExtantPair =
          (\b' b'' -> if blockSlot b' > blockSlot b'' then (b', b'') else (b'', b'))
            <$> elements bs
            <*> elements bs
        genAtLeastLowerExtant = do
          lowerBlock <- elements bs
          upperBlock <-
            genBlockFromGenSlot $
              SlotNo <$> choose (1 + blockRawSlot lowerBlock, numSlotsPerChunk ci * (maxRawChunk + 1) - 1)
          return (lowerBlock, upperBlock)
        genAtLeastUpperExtant = do
          upperBlock <- elements bs
          lowerBlock <- genBlockFromGenSlot $ SlotNo <$> choose (0, blockRawSlot upperBlock - 1)
          return (lowerBlock, upperBlock)
        genMaybeNeitherExtant = do
          b' <- genBlockFromGenSlot $ SlotNo <$> choose (0, numSlotsPerChunk ci * (maxRawChunk + 1) - 2)
          b'' <-
            genBlockFromGenSlot $
              SlotNo <$> choose (blockRawSlot b' + 1, numSlotsPerChunk ci * (maxRawChunk + 1) - 1)
          return (b', b'')
    (b', b'') <-
      oneof [genExtantPair, genAtLeastLowerExtant, genAtLeastUpperExtant, genMaybeNeitherExtant]
        `suchThat` (\(b', b'') -> blockHash b' /= blockHash b'')
    -- Take care of the order of the blocks' chunks w.r.t. one another.
    return (bs, ci, if blockSlot b' > blockSlot b'' then (b', b'') else (b'', b'))

-- FirstChunkNotAvailable is expected under this scenario.
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsBelowFirstChunk :: Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsBelowFirstChunk =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let getChunk = blockChunk chunkInfo
            chunkFrom = getChunk blockFrom
            minChunk = getMinChunk chunkInfo blocks
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        unless (chunkFrom < minChunk) $
          error $
            "Precondition violation: generated blockFrom is not actually in a lower chunk than all blocks: "
              ++ show (chunkFrom, minChunk)
        when (blockSlot blockFrom > blockSlot blockTo) $
          error $
            "Precondition violation: generated blockFrom's slot exceeds blockTo's: "
              ++ show (blockSlot blockFrom, blockSlot blockTo)
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            checkError expBound (OnDemand.FirstChunkNotAvailable obsBound chunk) =
              conjoin
                [ obsBound === expBound
                , chunk === ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot blockFrom)
                ]
            checkError _ e =
              counterexample ("Expected FirstChunkNotAvailable error but got different error: " ++ show e) False
            checkResult lowerBound =
              either
                (checkError lowerBound)
                (const $ counterexample "Expected error but got successful result" False)
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in checkResult lowerBound
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfoWithRoomForLowChunk
    -- Generate the lower bound block such that its chunk number is below the lowest chunk number for the chain.
    b' <-
      genBlockFromGenSlot $ SlotNo <$> choose (0, numSlotsPerChunk ci * unChunkNo (getMinChunk ci bs) - 1)
    let getChunk = blockChunk ci
        maxChunk = maximum $ map getChunk bs
    -- The only restriction here is that the upper bound block be later in time (greater slot)
    -- than the lower bound block.
    b'' <-
      oneof
        [ elements bs
        , genBlockFromGenSlot $
            SlotNo <$> choose (1 + blockRawSlot b', numSlotsPerChunk ci * (2 + unChunkNo maxChunk))
        ]
        `suchThat` ((/= blockHash b') . blockHash)
    return (bs, ci, (b', b''))

-- StreamBoundNotFound is to be expected here.
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsInExtantChunkButDoesNotExist :: Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsInExtantChunkButDoesNotExist =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        unless (blockChunk chunkInfo blockFrom `elem` Map.keys chunkedBlocks) $
          error "Precondition violation: generated blockFrom is not actually in an extant chunk"
        when (containsBlockPoint blocks blockFrom) $
          error "Precondition violation: generated blockFrom is already among all blocks"
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            checkError :: IllegalStreamOperation TestBlock -> Property
            checkError (OnDemand.StreamBoundNotFound (obsSlot, obsHash) _) =
              conjoin
                [ counterexample "stream bound slot" (obsSlot === blockSlot blockFrom)
                , counterexample "stream bound hash" (obsHash === blockHash blockFrom)
                ]
            checkError e =
              counterexample ("Expected StreamBoundNotFound error but got different error: " ++ show e) False
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either checkError (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfo
    let genByModification b = modifyBlockHash b <$> (arbitrary `suchThat` (/= blockHash b))
        chunks = map (blockChunk ci) bs
    -- Generate the lower bound block such that it's not part of the chain.
    lowerBoundBlock <-
      oneof
        [ elements bs >>= genByModification
        , genBlockFromGenSlot (elements chunks >>= genSlotForChunk ci)
            `suchThat` (not . containsBlockPoint bs)
        ]
    -- The only restriction here is that the upper bound block be later in time (greater slot)
    -- than the lower bound block.
    let minSlotUpper = 1 + blockRawSlot lowerBoundBlock
        maxSlotUpper = numSlotsPerChunk ci * (1 + unChunkNo (maximum chunks)) - 1
    upperBoundBlock <-
      genBlockFromGenSlot (SlotNo <$> choose (minSlotUpper, maxSlotUpper))
        `suchThat` ((/= blockHash lowerBoundBlock) . blockHash)
    return (bs, ci, (lowerBoundBlock, upperBoundBlock))

-- Here the upper bound won't be found, as it will be passed during the skipping of blocks to reach the lower bound.
prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromSlotIsGreaterThanToSlotButChunkOrderIsOKAndLowerBoundIsValid ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromSlotIsGreaterThanToSlotButChunkOrderIsOKAndLowerBoundIsValid =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
            chunkFrom = blockChunk chunkInfo blockFrom
            chunkTo = blockChunk chunkInfo blockTo
            slotFrom = blockSlot blockFrom
            slotTo = blockSlot blockTo
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        when (chunkFrom /= chunkTo) $
          error $
            "Precondition violation: blockFrom's chunk is not equal to blockTo's: "
              ++ show (chunkFrom, chunkTo)
        unless (slotFrom > slotTo) $
          error $
            "Precondition violation: generated blockFrom's slot is not actually greater than blockTo's: "
              ++ show (slotFrom, slotTo)
        unless (containsBlockPoint blocks blockFrom && containsBlockPoint blocks blockTo) $
          error "Precondition violation: generated stream bound blocks aren't both part of the blockchain."
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either
                      (checkStreamBoundsError lowerBound upperBound)
                      (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    -- Generate the blocks such that at least one chunk has multiple blocks,
    -- so that we can choose different blocks from the same chunk.
    (bs, ci) <-
      genBlocksAndChunkInfo
        `suchThat` (\(bs, ci) -> not . Map.null $ Map.filter ((> 1) . length) $ groupBlocksByChunk ci bs)
    let chunkedBlocks = groupBlocksByChunk ci bs
    chosenChunk <- elements $ map fst $ filter ((> 1) . length . snd) $ Map.toList chunkedBlocks
    let blockChoices = chunkedBlocks Map.! chosenChunk
    b' <- elements blockChoices `suchThat` ((/= minimum (map blockSlot blockChoices)) . blockSlot)
    b'' <- elements $ filter ((< blockRawSlot b') . blockRawSlot) blockChoices
    return (bs, ci, (b', b''))

-- Here the iteration should pull out the correct header hashes, respecting the inclusion or exclusion of the lower bound.
prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerStrictlyBelowUpper :: Property
prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerStrictlyBelowUpper =
  forAll myGen $ \(blocks, chunkInfo, (iFrom, iTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let blockFrom = blocks !! iFrom
            blockTo = blocks !! iTo
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        unless (blockSlot blockFrom < blockSlot blockTo) $
          error $
            "Lower bound must be less than upper bound; block indices: "
              ++ show (blockSlot blockFrom, blockSlot blockTo)
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            expHashesInclusive = map blockHash $ take (iTo - iFrom + 1) $ drop iFrom blocks
            expHashesExclusive = tail expHashesInclusive
        obsHashesInclusive <-
          OnDemand.onDemandIteratorForRange
            runtime
            GetHash
            (StreamFromInclusive $ blockRealPoint blockFrom)
            upperBound
            >>= iteratorToList
        obsHashesExclusive <-
          OnDemand.onDemandIteratorForRange
            runtime
            GetHash
            (StreamFromExclusive $ blockPoint blockFrom)
            upperBound
            >>= iteratorToList
        pure $
          conjoin
            [ counterexample "inclusive bound" $ obsHashesInclusive === expHashesInclusive
            , counterexample "exclusive bound" $ obsHashesExclusive === expHashesExclusive
            ]
 where
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfo `suchThat` ((> 1) . length . fst)
    i' <- chooseInt (0, length bs - 1)
    i'' <- elements $ [0 .. (i' - 1)] ++ [(i' + 1) .. (length bs - 1)]
    return (bs, ci, if i' < i'' then (i', i'') else (i'', i'))

-- Here the result is either a singleton or an empty, depending on the inclusion/exclusion of the lower bound.
prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerEqualToUpper :: Property
prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerEqualToUpper =
  forAll myGen $ \(blocks, chunkInfo, boundIndex) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
            boundBlock = blocks !! boundIndex
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive $ blockRealPoint boundBlock
            exclusiveLowerBound = StreamFromExclusive $ blockPoint boundBlock
        obsHashesInclusive <-
          OnDemand.onDemandIteratorForRange
            runtime
            GetHash
            (StreamFromInclusive $ blockRealPoint boundBlock)
            upperBound
            >>= iteratorToList
        obsExclusiveResult <-
          try
            ( OnDemand.onDemandIteratorForRange
                runtime
                GetHash
                exclusiveLowerBound
                upperBound
                >>= iteratorToList
            )
        pure $
          conjoin
            [ counterexample "inclusive bound" $ obsHashesInclusive === [blockHash boundBlock]
            , counterexample "exclusive bound" $
                either
                  (checkStreamBoundsError exclusiveLowerBound upperBound)
                  (const $ counterexample "Expected error but got successful result" False)
                  obsExclusiveResult
            ]
 where
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfo `suchThat` ((> 1) . length . fst)
    i <- chooseInt (0, length bs - 1)
    return (bs, ci, i)

checkStreamBoundsError ::
  StandardHash blk =>
  StreamFrom blk -> StreamTo blk -> OnDemand.IllegalStreamOperation blk -> Property
checkStreamBoundsError expFrom expTo (OnDemand.IllegalStreamBounds obsFrom obsTo) =
  conjoin
    [counterexample "lower bound" $ obsFrom === expFrom, counterexample "upper bound" $ obsTo === expTo]
checkStreamBoundsError _ _ e = counterexample ("Expected IllegalStreamBounds error but got different error: " ++ show e) False

-- LastChunkNotAvailable is expected here.
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsButUpperBoundChunkDoesNot ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsButUpperBoundChunkDoesNot =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let getChunk = blockChunk chunkInfo
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        unless (getChunk blockTo > maximum (map getChunk blocks)) $
          error "Precondition violation: blockTo's chunk isn't greater than max chunk among other blocks. "
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            expErr = OnDemand.lastChunkNotAvailable chunkInfo (StreamToInclusive $ blockRealPoint blockTo)
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either
                      (=== expErr)
                      (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    -- No restriction on the lower bound block; the upper bound block must just be greater in chunk number than all the other blocks.
    (bs, ci) <- genBlocksAndChunkInfo
    b' <- elements bs
    let upperChunk = ChunkNo (1 + maximum (map (unChunkNo . blockChunk ci) bs))
    b'' <-
      genBlockFromGenSlot (genSlotForChunk ci upperChunk) `suchThat` ((/= blockHash b') . blockHash)
    return (bs, ci, (b', b''))

-- StreamBoundNotFound is to be expected here.
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsAndUpperBoundChunkExistsButNotUpperBoundBlockItself ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsAndUpperBoundChunkExistsButNotUpperBoundBlockItself =
  forAll myGen $ \(blocks, chunkInfo, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        when (blockHash blockFrom == blockHash blockTo) $
          error "Precondition violation: Stream bounding blocks have the same hash"
        unless (containsBlockPoint blocks blockFrom) $
          error "Precondition violation: generated blockFrom is not actually in the blockchain."
        when (containsBlockPoint blocks blockTo) $
          error "Precondition violation: generated blockTo is in the blockchain."
        unless (blockSlot blockFrom < blockSlot blockTo) $
          error "Block for lower bound has slot not below block for upper bound."
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            checkError :: IllegalStreamOperation TestBlock -> Property
            checkError (OnDemand.StreamBoundNotFound (obsSlot, obsHash) _) =
              conjoin
                [ counterexample "stream bound slot" (obsSlot === blockSlot blockTo)
                , counterexample "stream bound hash" (obsHash === blockHash blockTo)
                ]
            checkError e =
              counterexample ("Expected StreamBoundNotFound error but got different error: " ++ show e) False
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either checkError (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, ci) <- genBlocksAndChunkInfo `suchThat` ((> 1) . length . fst)
    let genByModification b = modifyBlockHash b <$> (arbitrary `suchThat` (/= blockHash b))
        maxSlot = maximum $ map blockSlot bs
        maxChunk = maximum $ map (blockChunk ci) bs
    b' <- elements bs `suchThat` ((/= maxSlot) . blockSlot) -- Allow room for upper bound block.
    let s' = blockSlot b'
    -- For the upper bound, modify an existing block or choose a slot in an extant chunk and generate a novel block.
    b'' <-
      oneof
        [ elements (filter ((> s') . blockSlot) bs) >>= genByModification
        , genBlockFromGenSlot $
            SlotNo <$> choose (1 + unSlotNo s', numSlotsPerChunk ci * (1 + unChunkNo maxChunk) - 1)
        ]
        `suchThat` (\b -> not (containsBlockPoint bs b) && blockHash b /= blockHash b')
    return (bs, ci, (b', b''))

----------------------------------------------------------------------------------------------------------------------
-- Generators and helpers --------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------

instance Arbitrary SlotNo where
  arbitrary = SlotNo <$> arbitrary

instance Arbitrary TestHash where
  arbitrary = testHashFromList . (: []) <$> arbitrary

instance Arbitrary Validity where
  arbitrary = (\p -> if p then Valid else Invalid) <$> arbitrary

blockRawSlot :: TestBlock -> Word64
blockRawSlot = unSlotNo . blockSlot

buildSecondaryEntry ::
  forall blk.
  (GetHeader blk, HasBinaryBlockInfo blk) =>
  BlockOffset ->
  CRC ->
  blk ->
  Entry blk
buildSecondaryEntry offset checksum block =
  let BinaryBlockInfo{..} = getBinaryBlockInfo block
      tip = blockToTip block
   in Entry
        { blockOffset = offset
        , headerOffset = HeaderOffset headerOffset
        , headerSize = HeaderSize headerSize
        , checksum = checksum
        , headerHash = tipHash tip
        , blockOrEBB = Block (tipSlotNo tip)
        }

-- The ways to create a lower bound for streaming from a test block
buildersForStreamFrom :: [TestBlock -> StreamFrom TestBlock]
buildersForStreamFrom =
  [ StreamFromExclusive . blockPoint
  , StreamFromInclusive . blockRealPoint
  ]

checkIterWithStreamFromFails ::
  OnDemandRuntime IO TestBlock h ->
  (IllegalStreamOperation TestBlock -> Property) ->
  StreamFrom TestBlock ->
  IO Property
checkIterWithStreamFromFails runtime checkError streamBound =
  either checkError (const $ counterexample "Expected error but none occurred" False)
    <$> ( try (OnDemand.onDemandIteratorFrom runtime (GetPure ()) streamBound >>= iteratorToList) ::
            IO (Either (IllegalStreamOperation TestBlock) [()])
        )

-- | Canonical point is pair of slot number and hash.
containsBlockPoint :: [TestBlock] -> TestBlock -> Bool
containsBlockPoint bs b' = getPoint b' `elem` map getPoint bs
 where
  getPoint b = (blockSlot b, blockHash b)

genBlockFromGenSlot :: Gen SlotNo -> Gen TestBlock
genBlockFromGenSlot genSlot = genSlot >>= (\s -> uncurry (unsafeTestBlock s) <$> arbitrary)

-- Create blocks with unique slot numbers, within a relatively compact range.
genBlocks :: Int -> Gen [TestBlock]
genBlocks n = do
  hashes <- genUniqueHashes n
  valids <- vectorOf n arbitrary
  slots <- map (SlotNo . fromIntegral) . List.sort . take n <$> shuffle [0 .. (2 * n)]
  return $
    zipWith3
      unsafeTestBlock
      slots
      hashes
      valids

-- Reverse engineer a ChunkInfo valid for the given blocks, by looking at the greatest
-- gap between generated blocks' slot numbers.
genBlocksAndChunkInfo :: Gen ([TestBlock], ChunkInfo)
genBlocksAndChunkInfo = do
  numBlocks <- chooseInt (1, 20)
  blocks <- genBlocks numBlocks
  let rawSlots = map blockRawSlot blocks
      slotsPerChunk = 1 + maximum (zipWith (-) rawSlots (0 : rawSlots))
  return (blocks, UniformChunkSize $ ChunkSize False slotsPerChunk)

-- Make it so that at least one chunk is below the lowest chunk among generated blocks.
genBlocksAndChunkInfoWithRoomForLowChunk :: Gen ([TestBlock], ChunkInfo)
genBlocksAndChunkInfoWithRoomForLowChunk = do
  (bs, ci) <- genBlocksAndChunkInfo
  let bs' = dropWhile (\b -> unChunkNo (blockChunk ci b) < 1) bs
  if null bs'
    then genBlocksAndChunkInfoWithRoomForLowChunk
    else return (bs', ci)

-- Make it so that the minimal extant chunk has at least one unoccupied slot.
genBlocksAndChunkInfoWithRoomInMinChunk :: Gen ([TestBlock], ChunkInfo)
genBlocksAndChunkInfoWithRoomInMinChunk =
  genBlocksAndChunkInfo
    `suchThat` (\(bs, ci) -> minimum (map blockRawSlot bs) `mod` numSlotsPerChunk ci /= 0)

-- Random slot number in the given chunk
genSlotForChunk :: ChunkInfo -> ChunkNo -> Gen SlotNo
genSlotForChunk (UniformChunkSize ChunkSize{numRegularBlocks = s}) (ChunkNo n) = let lo = n * s in SlotNo <$> choose (lo, lo + s - 1)

genUniqueHashes :: Int -> Gen [TestHash]
genUniqueHashes n = map (\h -> testHashFromList [fromIntegral h]) <$> shuffle [1 .. n]

getMinChunk :: ChunkInfo -> [TestBlock] -> ChunkNo
getMinChunk ci = minimum . map (blockChunk ci)

incrementSlot :: TestBlock -> TestBlock
incrementSlot b = unsafeTestBlock (SlotNo $ 1 + blockRawSlot b) (blockHash b) (tbValid b)

iteratorToList :: Monad m => Iterator m blk b -> m [b]
iteratorToList = fmap reverse . useIterator (:) []

-- Convenience helper bundling the common pattern for creating a runtime for each test case
makeRuntimeWithNullRemoteAndNullLogging ::
  TmpDir ->
  ChunkInfo ->
  Map.Map ChunkNo [TestBlock] ->
  IO (OnDemand.OnDemandRuntime IO TestBlock HandleIO)
makeRuntimeWithNullRemoteAndNullLogging (TmpDir tmp) chunkInfo chunkedBlocks =
  OnDemand.newOnDemandRuntime $
    OnDemandConfig
      { odcRemote =
          RemoteStorageConfig
            { rscSrcUrl = getLocalUrl (1 + 2 ^ (16 :: Int))
            , rscDstDir = tmp
            , rscMaxRetries = RetryCount 0
            , rscBaseDelay = 0
            }
      , odcTracer = nullTracer
      , odcChunkInfo = chunkInfo
      , odcHasFS = fpToHasFS tmp
      , odcCodecConfig = TB.TestBlockCodecConfig
      , odcCheckIntegrity = const True
      , odcMaxCachedChunks = MaxCachedChunksCount . fromIntegral $ Map.size chunkedBlocks
      , odcPrefetchAhead = PrefetchChunksCount 0
      }

modifyBlockHash :: TestBlock -> TestHash -> TestBlock
modifyBlockHash b h = unsafeTestBlock (tbSlot b) h (tbValid b)

numSlotsPerChunk :: ChunkInfo -> Word64
numSlotsPerChunk (UniformChunkSize chunkSize) = numRegularBlocks chunkSize

unsafeTestBlock :: SlotNo -> TestHash -> Validity -> TestBlock
unsafeTestBlock slot hash valid = unsafeTestBlockWithPayload hash slot valid ()

-- Force full evaluation of the iterator.
useIterator :: Monad m => (b -> a -> a) -> a -> Iterator m blk b -> m a
useIterator combine acc0 iter = go iter $ pure acc0
 where
  go it acc = do
    maybeResult <- iteratorNext it
    case maybeResult of
      IteratorExhausted -> acc
      IteratorResult res -> go it (combine res <$> acc)

withTemp :: forall m a. (MonadIO m, MonadMask m) => (TmpDir -> m a) -> m a
withTemp useTmpDir = Temp.withSystemTempDirectory "iteration-test" (useTmpDir . TmpDir)

-- Helper in setup for a test case, writing the chunk file, primary index file, and secondary index file backing the given blocks for a single chunk
writeBlocks ::
  forall blk.
  ( ConvertRawHash blk
  , GetHeader blk
  , HasBinaryBlockInfo blk
  , Serialise blk
  ) =>
  TmpDir ->
  ChunkNo ->
  [blk] ->
  IO [FilePath]
writeBlocks (TmpDir folder) chunkNo blocks = do
  let rootFS = fpToHasFS folder
  blocksSizesAndChecksums <- withFile rootFS (fsPathChunkFile chunkNo) (WriteMode MustBeNew) $ \h -> traverse (\b -> (b,) <$> writeOneBlockOnly rootFS h b) blocks
  let offsets = map BlockOffset $ scanl (\acc (_, (s, _)) -> acc + s) 0 blocksSizesAndChecksums
      secondaryEntries =
        zipWith (\off (blk, (_, cs)) -> buildSecondaryEntry off cs blk) offsets blocksSizesAndChecksums
  Secondary.writeAllEntries rootFS chunkNo secondaryEntries
  case Primary.mk chunkNo $ map (fromIntegral . unBlockOffset) (NEL.init $ NEL.fromList offsets) of
    -- call to NEL.fromList safe here since offsets is created with scanl and will therefore be nonempty.
    Nothing ->
      -- no blocks, so no primary index, but create an empty file to satisfy the invariant that it must exist
      withFile rootFS (fsPathPrimaryIndexFile chunkNo) (WriteMode MustBeNew) $ \_ -> return ()
    Just index -> Primary.write rootFS chunkNo index
  return $
    map
      (\t -> folder </> Text.unpack (getFileName t chunkNo))
      [ChunkFile, PrimaryIndexFile, SecondaryIndexFile]

-- Setup for a test case, writing the chunk files, primary index files, and secondary index files backing the given blocks for all chunks
writeChunkFiles :: TmpDir -> Map.Map ChunkNo [TestBlock] -> IO ()
writeChunkFiles tmp chunkedBlocks = forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)

-- Write a single block to disk.
writeOneBlockOnly ::
  forall blk m h.
  (Serialise blk, Monad m) =>
  HasFS m h ->
  Handle h ->
  blk ->
  m (Word64, CRC)
writeOneBlockOnly hasFS currentChunkHandle = hPutAllCRC hasFS currentChunkHandle . CBOR.toLazyByteString . encode

----------------------------------------------------------------------------------------------------------------------
-- Property aggregation for export -----------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "iteration"
    [ testProperty
        "Basic iteration over headers is correct"
        prop_fullIterationOverChainHeadersRecapitulatesInput
    , testProperty
        "onDemandIteratorFrom is correct when using StreamFromInclusive for an extant point"
        prop_onDemandIteratorFromIsCorrectForStreamFromInclusive
    , testProperty
        "onDemandIteratorFrom is correct when using StreamFromExclusive for an extant point"
        prop_onDemandIteratorFromIsCorrectForStreamFromExclusive
    , testProperty
        "onDemandIteratorFrom errors when starting from a point between slot numbers within chain"
        prop_onDemandIteratorFromErrorsWhenStartingBetweenSlotNumbersWithinChain
    , testProperty
        "onDemandIteratorFrom errors when starting from a point with a slot number on chain but wrong header hash"
        prop_onDemandIteratorFromErrorsWhenStartingWithSlotNumberOnChainButWrongHeaderHash
    , testProperty
        "onDemandIteratorFrom errors when starting from after the last block but within the same chunk"
        prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockButWithinSameChunk
    , testProperty
        "onDemandIteratorFrom errors when starting from after the last block and in a greater chunk"
        prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk
    , testProperty
        "onDemandIteratorFrom errors when starting from before the first block but within the same chunk"
        prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk
    , testProperty
        "onDemandIteratorFrom errors when starting from before the first block and in a lesser chunk"
        prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk
    , testProperty
        "onDemandIteratorForRange errors correctly when stream bound hashes match and lower bound is exclusive"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenStreamBoundHashesMatchAndLowerBoundIsExclusive
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound is after upper bound"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsAfterUpperBound
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound is below first chunk"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsBelowFirstChunk
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound is in an extant chunk but does not exist"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsInExtantChunkButDoesNotExist
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound slot is greater than upper bound slot but in same chunk"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromSlotIsGreaterThanToSlotButChunkOrderIsOKAndLowerBoundIsValid
    , testProperty
        "onDemandIteratorForRange is correct for valid bounds with lower strictly less than upper"
        prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerStrictlyBelowUpper
    , testProperty
        "onDemandIteratorForRange is correct for valid bounds with lower equal to upper"
        prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerEqualToUpper
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound exists but upper bound chunk does not"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsButUpperBoundChunkDoesNot
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound exists and upper bound chunk exists but not the block itself"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsAndUpperBoundChunkExistsButNotUpperBoundBlockItself
    ]
