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
import Control.Exception (SomeException, try)
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
  ( IllegalStreamResult (StreamBoundNotFound)
  , OnDemandConfig (..)
  , OnDemandRuntime (..)
  , OnDemandState (..)
  )
import qualified GenesisSyncAccelerator.OnDemand as OnDemand
import GenesisSyncAccelerator.RemoteStorage (FileType (..), RemoteStorageConfig (..), getFileName)
import GenesisSyncAccelerator.Types (MaxCachedChunksCount (..), PrefetchChunksCount (..))
import GenesisSyncAccelerator.Util (fpToHasFS)
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
  forAll genBlocksAndChunkSize $ \(blocks, chunkSize) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
  forAll (genBlocksAndChunkSize >>= (\(bs, sz) -> (bs,sz,) <$> chooseInt (0, length bs - 1))) $ \(blocks, chunkSize, startIndex) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
  forAll (genBlocksAndChunkSize >>= (\(bs, sz) -> (bs,sz,) <$> chooseInt (0, length bs - 1))) $ \(blocks, chunkSize, startIndex) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
  forAll (genBlocksAndChunkSize `suchThat` uncurry thereIsRoomForOneMoreSlotInFinalChunk) $ \(blocks, chunkSize) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let afterLastBlock = incrementSlot $ last blocks
            streamBound = StreamFromInclusive $ blockRealPoint afterLastBlock
            expErr = OnDemand.StreamBoundNotFound (blockSlot afterLastBlock, blockHash afterLastBlock) Nothing
        checkIterWithStreamFromFails runtime (=== expErr) streamBound
 where
  thereIsRoomForOneMoreSlotInFinalChunk :: [TestBlock] -> ChunkSize -> Bool
  thereIsRoomForOneMoreSlotInFinalChunk blocks ChunkSize{numRegularBlocks = slotsPerChunk} =
    maximum (map blockRawSlot blocks) `mod` slotsPerChunk < (slotsPerChunk - 1)

prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk =
  forAll myGen $ \(blocks, chunkSize, badBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let checkError (OnDemand.StreamBoundNotFound (s, h) _) = conjoin [s === blockSlot badBlock, h === blockHash badBlock]
            checkError e = counterexample ("Expected StreamBoundNotFound error; got: " ++ show e) False
        conjoin
          <$> traverse
            (\buildBound -> checkIterWithStreamFromFails runtime checkError $ buildBound badBlock)
            buildersForStreamFrom
 where
  myGen = do
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <- genBlocksAndChunkSizeWithRoomInMinChunk
    let leastChunk = getMinChunk sz bs
    slot <-
      SlotNo <$> choose (unChunkNo leastChunk * numSlotsPerChunk, minimum (map blockRawSlot bs) - 1)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, sz, unsafeTestBlock slot hash valid)

prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk =
  forAll myGen $ \(blocks, chunkSize, extraBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let getExpErr bound = OnDemand.FirstChunkNotAvailable bound (blockChunk chunkInfo extraBlock)
        conjoin
          <$> traverse
            ( \buildBound -> let b = buildBound extraBlock in checkIterWithStreamFromFails runtime (=== getExpErr b) b
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <- genBlocksAndChunkSize
    let chunkInfo = UniformChunkSize sz
        greatestChunk = ChunkLayout.chunkIndexOfSlot chunkInfo $ maximum $ map blockSlot bs
        firstSlotBeyondLastChunk = (1 + unChunkNo greatestChunk) * numSlotsPerChunk
    slot <-
      SlotNo <$> choose (firstSlotBeyondLastChunk, firstSlotBeyondLastChunk + 3 * numSlotsPerChunk)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, sz, unsafeTestBlock slot hash valid)

prop_onDemandIteratorFromErrorsWhenStartingBetweenSlotNumbersWithinChain :: Property
prop_onDemandIteratorFromErrorsWhenStartingBetweenSlotNumbersWithinChain =
  forAll myGen $ \(blocks, chunkSize, nonExistentBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        when (blockSlot nonExistentBlock `elem` map blockSlot blocks) $
          error "Precondition violation: generated start block with slot already in use"
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
  myGen = do
    let offset xs = zip (drop 1 xs) xs
        getSlots = map blockSlot
        getDiffs = map (uncurry (-)) . offset
    (bs, sz) <- genBlocksAndChunkSize `suchThat` (\(bs, _) -> any (> 1) (getDiffs $ getSlots bs))
    let slotOptions = concatMap (\(b, a) -> if b - a <= 1 then [] else [(a + 1) .. (b - 1)]) $ offset $ getSlots bs
    case slotOptions of
      -- Need at least 1 from which to call elements
      [] -> do
        error $ "Failed to generate slotOptions; slots: " ++ show (getSlots bs)
      _ -> do
        extraSlot <- elements slotOptions
        extraHash <- arbitrary
        extraValid <- arbitrary
        return (bs, sz, unsafeTestBlock extraSlot extraHash extraValid)

prop_onDemandIteratorFromErrorsWhenStartingWithSlotNumberOnChainButWrongHeaderHash :: Property
prop_onDemandIteratorFromErrorsWhenStartingWithSlotNumberOnChainButWrongHeaderHash =
  forAll myGen $ \(blocks, chunkSize, nonExistentBlock) ->
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
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
  myGen = do
    (bs, sz) <- genBlocksAndChunkSize
    b <- elements bs
    newHash <- arbitrary `suchThat` (/= blockHash b)
    let newBlock = unsafeTestBlock (blockSlot b) newHash (tbValid b)
    return (bs, sz, newBlock)

prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk =
  forAll myGen $ \(blocks, chunkSize, badBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let getExpErr bound = OnDemand.FirstChunkNotAvailable bound (blockChunk chunkInfo badBlock)
        conjoin
          <$> traverse
            ( \buildBound -> let b = buildBound badBlock in checkIterWithStreamFromFails runtime (=== getExpErr b) b
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <- genBlocksAndChunkSizeWithRoomForLowChunk
    let maxSlotRaw = numSlotsPerChunk * unChunkNo (getMinChunk sz bs) - 1
    slot <- SlotNo <$> choose (0, maxSlotRaw)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, sz, unsafeTestBlock slot hash valid)

----------------------------------------------------------------------------------------------------------------------
-- OnDemand.onDemandIteratorForRange ---------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------

prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromChunkIsGreaterThanToChunk ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromChunkIsGreaterThanToChunk =
  forAll myGen $ \(blocks, chunkSize, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
            chunkFrom = blockChunk chunkInfo blockFrom
            chunkTo = blockChunk chunkInfo blockTo
        unless (chunkFrom > chunkTo) $
          error $
            "Precondition violation: generated blockFrom's chunk is not actually after blockTo's: "
              ++ show (chunkFrom, chunkTo)
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            checkError :: StreamFrom blk -> SomeException -> Property
            checkError _ e =
              let bounds = (blockRawChunk chunkInfo blockFrom, blockRawChunk chunkInfo blockTo)
                  expPrefix = "Illegal chunk range bounds: " ++ show bounds
               in counterexample ("expPrefix: " ++ expPrefix ++ ", actual error: " ++ show e) $
                    expPrefix `List.isPrefixOf` show e
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either
                      (checkError lowerBound)
                      (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, sz) <- genBlocksAndChunkSizeWithRoomForLowChunk `suchThat` ((> 1) . length . fst)
    let chunkInfo = UniformChunkSize sz
        getRawChunk = unChunkNo . blockChunk chunkInfo
        maxRawChunk = maximum (map getRawChunk bs) + 1
        genExtantPair = ((,) <$> elements bs <*> elements bs) `suchThat` uncurry (/=)
        genAtLeastLowerExtant = do
          lowerBlock <- elements bs
          upperChunk <- ChunkNo <$> choose (getRawChunk lowerBlock, maxRawChunk)
          upperBlock <- genBlockFromGenSlot $ genSlotForChunk sz upperChunk
          return (lowerBlock, upperBlock)
        genAtLeastUpperExtant = do
          upperBlock <- elements bs
          lowerChunk <- ChunkNo <$> choose (0, minimum (map getRawChunk bs) - 1)
          lowerBlock <- genBlockFromGenSlot $ genSlotForChunk sz lowerChunk
          return (lowerBlock, upperBlock)
        genMaybeNeitherExtant = do
          c' <- ChunkNo <$> choose (0, maxRawChunk)
          c'' <- ChunkNo <$> choose (unChunkNo c' + 1, maxRawChunk + 1)
          b' <- genBlockFromGenSlot $ genSlotForChunk sz c'
          b'' <- genBlockFromGenSlot $ genSlotForChunk sz c''
          return (b', b'')
    (b', b'') <-
      oneof [genExtantPair, genAtLeastLowerExtant, genAtLeastUpperExtant, genMaybeNeitherExtant]
        `suchThat` (\(b', b'') -> getRawChunk b' /= getRawChunk b'')
    return (bs, sz, if blockChunk chunkInfo b' > blockChunk chunkInfo b'' then (b', b'') else (b'', b'))

prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsBelowFirstChunkRegardlessOfUpperBound ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsBelowFirstChunkRegardlessOfUpperBound =
  forAll myGen $ \(blocks, chunkSize, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            getChunk = blockChunk chunkInfo
            chunkFrom = getChunk blockFrom
            minChunk = getMinChunk chunkSize blocks
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
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <- genBlocksAndChunkSizeWithRoomForLowChunk
    b' <-
      genBlockFromGenSlot $ SlotNo <$> choose (0, numSlotsPerChunk * unChunkNo (getMinChunk sz bs) - 1)
    let getChunk = blockChunk (UniformChunkSize sz)
        maxChunk = maximum $ map getChunk bs
    b'' <-
      oneof
        [ elements bs
        , genBlockFromGenSlot $
            SlotNo
              <$> choose
                (1 + blockRawSlot b', numSlotsPerChunk * (2 + unChunkNo maxChunk))
        ]
    return (bs, sz, (b', b''))

prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsInExtantChunkButDoesNotExist ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsInExtantChunkButDoesNotExist =
  forAll myGen $ \(blocks, chunkSize, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        unless (blockChunk chunkInfo blockFrom `elem` Map.keys chunkedBlocks) $
          error "Precondition violation: generated blockFrom is not actually in an extant chunk"
        when (blockFrom `elem` blocks) $
          error "Precondition violation: generated blockFrom is already among all blocks"
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            checkError :: OnDemand.IllegalStreamResult TestBlock -> Property
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
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <- genBlocksAndChunkSize
    let genByModification b = (\h -> unsafeTestBlock (tbSlot b) h (tbValid b)) <$> (arbitrary `suchThat` (/= blockHash b))
        chunks = map (blockChunk (UniformChunkSize sz)) bs
    lowerBoundBlock <-
      oneof
        [elements bs >>= genByModification, genBlockFromGenSlot (elements chunks >>= genSlotForChunk sz)]
    upperBoundBlock <-
      genBlockFromGenSlot $
        SlotNo
          <$> choose (1 + blockRawSlot lowerBoundBlock, numSlotsPerChunk * (1 + unChunkNo (maximum chunks)) - 1)
    return (bs, sz, (lowerBoundBlock, upperBoundBlock))

prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromSlotIsGreaterThanToSlotButChunkOrderIsOKAndLowerBoundIsValid ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromSlotIsGreaterThanToSlotButChunkOrderIsOKAndLowerBoundIsValid =
  forAll myGen $ \(blocks, chunkSize, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
            chunkFrom = blockChunk chunkInfo blockFrom
            chunkTo = blockChunk chunkInfo blockTo
            slotFrom = blockSlot blockFrom
            slotTo = blockSlot blockTo
        when (chunkFrom > chunkTo) $
          error $
            "Precondition violation: blockFrom's chunk is greater than blockTo's: "
              ++ show (chunkFrom, chunkTo)
        unless (slotFrom > slotTo) $
          error $
            "Precondition violation: generated blockFrom's slot is not actually greater than blockTo's: "
              ++ show (slotFrom, slotTo)
        unless (blockFrom `elem` blocks && blockTo `elem` blocks) $
          error "Precondition violation: generated stream bound blocks aren't both part of the blockchain."
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive (blockRealPoint blockTo)
            checkError :: OnDemand.IllegalStreamResult TestBlock -> Property
            checkError (OnDemand.StreamBoundNotFound (obsSlot, obsHash) _) =
              conjoin
                [ obsSlot === blockSlot blockTo
                , obsHash === blockHash blockTo
                ]
            checkError e = counterexample ("Expected StreamBoundNotFound error but got different error: " ++ show e) False
        conjoin
          <$> traverse
            ( \buildLowerBound ->
                let lowerBound = buildLowerBound blockFrom
                 in either
                      checkError
                      (const $ counterexample "Expected error but got successful result" False)
                      <$> try
                        (OnDemand.onDemandIteratorForRange runtime (GetPure ()) lowerBound upperBound >>= iteratorToList)
            )
            buildersForStreamFrom
 where
  myGen = do
    (bs, sz) <-
      genBlocksAndChunkSize
        `suchThat` ( \(bs, sz) -> not . Map.null $ Map.filter ((> 1) . length) $ groupBlocksByChunk (UniformChunkSize sz) bs
                   )
    let chunkedBlocks = groupBlocksByChunk (UniformChunkSize sz) bs
    chosenChunk <- elements $ map fst $ filter ((> 1) . length . snd) $ Map.toList chunkedBlocks
    let blockChoices = chunkedBlocks Map.! chosenChunk
    b' <- elements blockChoices `suchThat` ((/= minimum (map blockSlot blockChoices)) . blockSlot)
    b'' <- elements $ filter ((< blockRawSlot b') . blockRawSlot) blockChoices
    return (bs, sz, (b', b''))

prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerStrictlyBelowUpper :: Property
prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerStrictlyBelowUpper =
  forAll myGen $ \(blocks, chunkSize, (iFrom, iTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let blockFrom = blocks !! iFrom
            blockTo = blocks !! iTo
            chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
    (bs, sz) <- genBlocksAndChunkSize `suchThat` ((> 1) . length . fst)
    i' <- chooseInt (0, length bs - 1)
    i'' <- elements $ [0 .. (i' - 1)] ++ [(i' + 1) .. (length bs - 1)]
    return (bs, sz, if i' < i'' then (i', i'') else (i'', i'))

prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerEqualToUpper :: Property
prop_onDemandIteratorForRangeIsCorrectWhenGivenTwoValidBoundsWithLowerEqualToUpper =
  forAll myGen $ \(blocks, chunkSize, boundIndex) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
            boundBlock = blocks !! boundIndex
        writeChunkFiles tmp chunkedBlocks
        runtime <- makeRuntimeWithNullRemoteAndNullLogging tmp chunkInfo chunkedBlocks
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let upperBound = StreamToInclusive $ blockRealPoint boundBlock
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
                (StreamFromExclusive $ blockPoint boundBlock)
                upperBound
                >>= iteratorToList
            )
        let checkError :: OnDemand.IllegalStreamResult TestBlock -> Property
            checkError (StreamBoundNotFound (s, h) _) =
              conjoin
                [ counterexample "block slot" $ s === blockSlot boundBlock
                , counterexample "block hash" $ h === blockHash boundBlock
                ]
            checkError e = counterexample ("Expected StreamBoundNotFound error but got different error: " ++ show e) False
            checkResult = either checkError (const $ counterexample "Expected error but got successful result" False)
        pure $
          conjoin
            [ counterexample "inclusive bound" $ obsHashesInclusive === [blockHash boundBlock]
            , counterexample "exclusive bound" $ checkResult obsExclusiveResult
            ]
 where
  myGen = do
    (bs, sz) <- genBlocksAndChunkSize `suchThat` ((> 1) . length . fst)
    i <- choose (0, length bs - 1)
    return (bs, sz, i)

prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsButUpperBoundChunkDoesNot ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsButUpperBoundChunkDoesNot =
  forAll myGen $ \(blocks, chunkSize, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            getChunk = blockChunk chunkInfo
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
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
            expErr = OnDemand.LastChunkNotAvailable (StreamToInclusive $ blockRealPoint blockTo) (getChunk blockTo)
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
    (bs, sz) <- genBlocksAndChunkSize
    b' <- elements bs
    b'' <-
      genBlockFromGenSlot $
        genSlotForChunk sz $
          ChunkNo (1 + maximum (map (blockRawChunk $ UniformChunkSize sz) bs))
    return (bs, sz, (b', b''))

prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsAndUpperBoundChunkExistsButNotUpperBoundBlockItself ::
  Property
prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundExistsAndUpperBoundChunkExistsButNotUpperBoundBlockItself =
  forAll myGen $ \(blocks, chunkSize, (blockFrom, blockTo)) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks = groupBlocksByChunk chunkInfo blocks
        unless (blockFrom `elem` blocks) $
          error "Precondition violation: generated blockFrom is not actually in the blockchain."
        when (blockTo `elem` blocks) $
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
            checkError :: OnDemand.IllegalStreamResult TestBlock -> Property
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
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <-
      genBlocksAndChunkSize `suchThat` ((> 1) . length . fst)
    let genByModification b = (\h -> unsafeTestBlock (tbSlot b) h (tbValid b)) <$> (arbitrary `suchThat` (/= blockHash b))
        getChunk = blockChunk $ UniformChunkSize sz
        maxChunk = maximum $ map getChunk bs
    b' <- elements bs `suchThat` ((/= maxChunk) . getChunk)
    let s' = blockSlot b'
    b'' <-
      oneof
        [ elements (filter ((> s') . blockSlot) bs) >>= genByModification
        , genBlockFromGenSlot $
            SlotNo <$> choose (1 + unSlotNo s', numSlotsPerChunk * (1 + unChunkNo maxChunk) - 1)
        ]
        `suchThat` (`notElem` bs)
    return (bs, sz, (b', b''))

----------------------------------------------------------------------------------------------------------------------
-- Generators and helpers --------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------

instance Arbitrary SlotNo where
  arbitrary = SlotNo <$> arbitrary

instance Arbitrary TestHash where
  arbitrary = testHashFromList . (: []) <$> arbitrary

instance Arbitrary Validity where
  arbitrary = (\p -> if p then Valid else Invalid) <$> arbitrary

blockRawChunk :: ChunkInfo -> TestBlock -> Word64
blockRawChunk ci = unChunkNo . blockChunk ci

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

buildersForStreamFrom :: [TestBlock -> StreamFrom TestBlock]
buildersForStreamFrom =
  [ StreamFromExclusive . blockPoint
  , StreamFromInclusive . blockRealPoint
  ]

checkIterWithStreamFromFails ::
  OnDemandRuntime IO TestBlock h ->
  (OnDemand.IllegalStreamResult TestBlock -> Property) ->
  StreamFrom TestBlock ->
  IO Property
checkIterWithStreamFromFails runtime checkError streamBound =
  either checkError (const $ counterexample "Expected error but none occurred" False)
    <$> ( try (OnDemand.onDemandIteratorFrom runtime (GetPure ()) streamBound >>= iteratorToList) ::
            IO (Either (OnDemand.IllegalStreamResult TestBlock) [()])
        )

genBlockFromGenSlot :: Gen SlotNo -> Gen TestBlock
genBlockFromGenSlot genSlot = genSlot >>= (\s -> uncurry (unsafeTestBlock s) <$> arbitrary)

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

genBlocksAndChunkSize :: Gen ([TestBlock], ChunkSize)
genBlocksAndChunkSize = do
  numBlocks <- chooseInt (1, 20)
  blocks <- genBlocks numBlocks
  let rawSlots = map blockRawSlot blocks
      numSlotsPerChunk = 1 + maximum (zipWith (-) rawSlots (0 : rawSlots))
  return (blocks, ChunkSize False numSlotsPerChunk)

genBlocksAndChunkSizeWithRoomForLowChunk :: Gen ([TestBlock], ChunkSize)
genBlocksAndChunkSizeWithRoomForLowChunk = do
  (bs, sz) <- genBlocksAndChunkSize
  let bs' = dropWhile (\b -> unChunkNo (blockChunk (UniformChunkSize sz) b) < 1) bs
  if null bs'
    then genBlocksAndChunkSizeWithRoomForLowChunk
    else return (bs', sz)

genBlocksAndChunkSizeWithRoomInMinChunk :: Gen ([TestBlock], ChunkSize)
genBlocksAndChunkSizeWithRoomInMinChunk =
  genBlocksAndChunkSize
    `suchThat` ( \(bs, ChunkSize{numRegularBlocks = numSlotsPerChunk}) -> minimum (map blockRawSlot bs) `mod` numSlotsPerChunk /= 0
               )

genSlotForChunk :: ChunkSize -> ChunkNo -> Gen SlotNo
genSlotForChunk ChunkSize{numRegularBlocks = s} (ChunkNo n) = let lo = n * s in SlotNo <$> choose (lo, lo + s - 1)

genUniqueHashes :: Int -> Gen [TestHash]
genUniqueHashes n = map (\h -> testHashFromList [fromIntegral h]) <$> shuffle [1 .. n]

getMinChunk :: ChunkSize -> [TestBlock] -> ChunkNo
getMinChunk chunkSize = minimum . map (blockChunk (UniformChunkSize chunkSize))

incrementSlot :: TestBlock -> TestBlock
incrementSlot b = unsafeTestBlock (SlotNo $ 1 + blockRawSlot b) (blockHash b) (tbValid b)

iteratorToList :: Monad m => Iterator m blk b -> m [b]
iteratorToList = fmap reverse . useIterator (:) []

makeRuntimeWithNullRemoteAndNullLogging ::
  TmpDir ->
  ChunkInfo ->
  Map.Map ChunkNo [TestBlock] ->
  IO (OnDemand.OnDemandRuntime IO TestBlock HandleIO)
makeRuntimeWithNullRemoteAndNullLogging (TmpDir tmp) chunkInfo chunkedBlocks =
  OnDemand.newOnDemandRuntime $
    OnDemandConfig
      { odcRemote =
          RemoteStorageConfig{rscSrcUrl = getLocalUrl (1 + 2 ^ (16 :: Int)), rscDstDir = tmp}
      , odcTracer = nullTracer
      , odcChunkInfo = chunkInfo
      , odcHasFS = fpToHasFS tmp
      , odcCodecConfig = TB.TestBlockCodecConfig
      , odcCheckIntegrity = const True
      , odcMaxCachedChunks = MaxCachedChunksCount . fromIntegral $ Map.size chunkedBlocks
      , odcPrefetchAhead = PrefetchChunksCount 0
      }

unsafeTestBlock :: SlotNo -> TestHash -> Validity -> TestBlock
unsafeTestBlock slot hash valid = unsafeTestBlockWithPayload hash slot valid ()

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

writeChunkFiles :: TmpDir -> Map.Map ChunkNo [TestBlock] -> IO ()
writeChunkFiles tmp chunkedBlocks = forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)

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
        "onDemandIteratorForRange errors correctly when lower bound chunk is greater than upper bound chunk"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenFromChunkIsGreaterThanToChunk
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound is below first chunk, regardless of upper bound"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsBelowFirstChunkRegardlessOfUpperBound
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound is in an extant chunk but does not exist, regardless of upper bound"
        prop_onDemandIteratorForRangeErrorsCorrectlyWhenLowerBoundIsInExtantChunkButDoesNotExist
    , testProperty
        "onDemandIteratorForRange errors correctly when lower bound slot is greater than upper bound slot but in same chunk, and lower bound is valid"
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
