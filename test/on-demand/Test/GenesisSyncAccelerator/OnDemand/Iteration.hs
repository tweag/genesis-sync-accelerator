{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.OnDemand.Iteration (tests) where

import Cardano.Slotting.Slot (SlotNo (..))
import qualified Codec.CBOR.Write as CBOR
import Codec.Serialise (Serialise (encode))
import Control.Exception (try)
import Control.Monad (forM_, when)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.List as List
import qualified Data.List.NonEmpty as NEL (fromList, init)
import qualified Data.Map as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Conc (atomically)
import GenesisSyncAccelerator.OnDemand
  ( OnDemandConfig (..)
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
  )
import Ouroboros.Consensus.Block.RealPoint (blockRealPoint)
import Ouroboros.Consensus.Storage.Common
  ( BinaryBlockInfo (..)
  , BlockComponent (..)
  , StreamFrom (..)
  )
import Ouroboros.Consensus.Storage.ImmutableDB.API
  ( Iterator (..)
  , IteratorResult (..)
  , Tip (..)
  , blockToTip
  , tipHash
  )
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks (ChunkSize (..))
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkInfo (..), ChunkNo (..))
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
import Ouroboros.Network.Block (blockHash, blockPoint, blockSlot)
import System.FS.API (AllowExisting (MustBeNew), HasFS, OpenMode (..), withFile)
import System.FS.API.Types (Handle)
import System.FS.CRC (CRC, hPutAllCRC)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Utilities (getLocalUrl)
import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import Test.Util.TestBlock
  ( TestBlock
  , TestBlockWith (tbValid)
  , TestHash
  , Validity (..)
  , testHashFromList
  , unsafeTestBlockWithPayload
  )
import qualified Test.Util.TestBlock as TB
import "contra-tracer" Control.Tracer (nullTracer)

prop_fullIterationOverChainHeadersRecapitulatesInput :: Property
prop_fullIterationOverChainHeadersRecapitulatesInput =
  forAll genBlocksAndChunkSize $ \(blocks, chunkSize) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
        forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
        forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
        forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
            maxChunk = maximum (Map.keys chunkedBlocks)
        forM_ (map ChunkNo [0 .. (unChunkNo maxChunk)]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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
    maximum (map (unSlotNo . blockSlot) blocks) `mod` slotsPerChunk < (slotsPerChunk - 1)

prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockButWithinSameChunk =
  forAll myGen $ \(blocks, chunkSize, badBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
            maxChunk = maximum (Map.keys chunkedBlocks)
        forM_ (map ChunkNo [0 .. (unChunkNo maxChunk)]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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
            [StreamFromExclusive . blockPoint, StreamFromInclusive . blockRealPoint]
 where
  myGen = do
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <-
      genBlocksAndChunkSize
        `suchThat` ( \(bs, ChunkSize{numRegularBlocks = numSlotsPerChunk}) -> minimum (map (unSlotNo . blockSlot) bs) `mod` numSlotsPerChunk /= 0
                   )
    let leastChunk = getMinChunk sz bs
        minSlotRaw = unChunkNo leastChunk * numSlotsPerChunk
        maxSlotRaw = minimum (map (unSlotNo . blockSlot) bs) - 1
    slot <- SlotNo <$> choose (minSlotRaw, maxSlotRaw)
    hash <- arbitrary
    valid <- arbitrary
    return (bs, sz, unsafeTestBlock slot hash valid)

prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromAfterLastBlockAndInAnotherChunk =
  forAll myGen $ \(blocks, chunkSize, extraBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
            maxChunk = maximum (Map.keys chunkedBlocks)
        forM_ (map ChunkNo [0 .. (unChunkNo maxChunk)]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let extraBlockChunk = ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot extraBlock)
            getExpErr bound = OnDemand.FirstChunkNotAvailable bound extraBlockChunk
        conjoin
          <$> traverse
            ( \buildBound -> let b = buildBound extraBlock in checkIterWithStreamFromFails runtime (=== getExpErr b) b
            )
            [StreamFromExclusive . blockPoint, StreamFromInclusive . blockRealPoint]
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

prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk :: Property
prop_onDemandIteratorFromErrorsWhenStartingFromBeforeFirstBlockAndInLowerChunk =
  forAll myGen $ \(blocks, chunkSize, badBlock) ->
    ioProperty $
      withTemp $ \tmp -> do
        let chunkInfo = UniformChunkSize chunkSize
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
            maxChunk = maximum (Map.keys chunkedBlocks)
        forM_ (map ChunkNo [0 .. (unChunkNo maxChunk)]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar
            (odrState runtime)
            state{odsCachedChunks = Map.keysSet chunkedBlocks}
        let badBlockChunk = ChunkLayout.chunkIndexOfSlot chunkInfo $ blockSlot badBlock
            getExpErr bound = OnDemand.FirstChunkNotAvailable bound badBlockChunk
        conjoin
          <$> traverse
            ( \buildBound -> let b = buildBound badBlock in checkIterWithStreamFromFails runtime (=== getExpErr b) b
            )
            [StreamFromExclusive . blockPoint, StreamFromInclusive . blockRealPoint]
 where
  genWithSpace = do
    (bs, sz) <- genBlocksAndChunkSize
    if null $
      dropWhile
        (\b -> unChunkNo (ChunkLayout.chunkIndexOfSlot (UniformChunkSize sz) (blockSlot b)) < 1)
        bs
      then genWithSpace
      else return (bs, sz)
  myGen = do
    (bs, sz@ChunkSize{numRegularBlocks = numSlotsPerChunk}) <- genWithSpace
    let maxSlotRaw = numSlotsPerChunk * unChunkNo (getMinChunk sz bs) - 1
    slot <- SlotNo <$> choose (0, maxSlotRaw)
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
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
        forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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
            (checkIterWithStreamFromFails runtime checkError)
            [ StreamFromExclusive $ blockPoint nonExistentBlock
            , StreamFromInclusive $ blockRealPoint nonExistentBlock
            ]
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
            chunkedBlocks =
              foldr
                ( \b acc ->
                    Map.insertWith (\_ old -> b : old) (ChunkLayout.chunkIndexOfSlot chunkInfo (blockSlot b)) [b] acc
                )
                Map.empty
                blocks
        forM_ (map ChunkNo [0 .. (unChunkNo (maximum (Map.keys chunkedBlocks)))]) $ \cn -> writeBlocks tmp cn (Map.findWithDefault [] cn chunkedBlocks)
        runtime <-
          let cfg =
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
           in OnDemand.newOnDemandRuntime cfg
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

instance Arbitrary SlotNo where
  arbitrary = SlotNo <$> arbitrary

instance Arbitrary TestHash where
  arbitrary = testHashFromList . (: []) <$> arbitrary

instance Arbitrary Validity where
  arbitrary = (\p -> if p then Valid else Invalid) <$> arbitrary

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
  let rawSlots = map (unSlotNo . blockSlot) blocks
      numSlotsPerChunk = 1 + maximum (zipWith (-) rawSlots (0 : rawSlots))
  return (blocks, ChunkSize False numSlotsPerChunk)

genUniqueHashes :: Int -> Gen [TestHash]
genUniqueHashes n = map (\h -> testHashFromList [fromIntegral h]) <$> shuffle [1 .. n]

getMinChunk :: ChunkSize -> [TestBlock] -> ChunkNo
getMinChunk chunkSize = ChunkLayout.chunkIndexOfSlot (UniformChunkSize chunkSize) . minimum . map blockSlot

incrementSlot :: TestBlock -> TestBlock
incrementSlot b = unsafeTestBlock (SlotNo $ 1 + unSlotNo (blockSlot b)) (blockHash b) (tbValid b)

iteratorToList :: Monad m => Iterator m blk b -> m [b]
iteratorToList = fmap reverse . useIterator (:) []

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

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "iteration-test"

writeBlocks ::
  forall blk.
  ( ConvertRawHash blk
  , GetHeader blk
  , HasBinaryBlockInfo blk
  , Serialise blk
  ) =>
  FilePath ->
  ChunkNo ->
  [blk] ->
  IO [FilePath]
writeBlocks folder chunkNo blocks = do
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

writeOneBlockOnly ::
  forall blk m h.
  (Serialise blk, Monad m) =>
  HasFS m h ->
  Handle h ->
  blk ->
  m (Word64, CRC)
writeOneBlockOnly hasFS currentChunkHandle = hPutAllCRC hasFS currentChunkHandle . CBOR.toLazyByteString . encode

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
    ]
