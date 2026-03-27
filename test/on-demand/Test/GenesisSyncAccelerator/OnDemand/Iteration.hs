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
import Control.Monad (forM_)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.List as List
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NEL (fromList, init, map, scanl, toList, zipWith)
import qualified Data.List.Split as Split
import qualified Data.Set as Set
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
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Util (fsPathChunkFile)
import Ouroboros.Consensus.Storage.Serialisation (HasBinaryBlockInfo (..))
import Ouroboros.Consensus.Util.NormalForm.StrictTVar (readTVarIO, writeTVar)
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
  , TestHash
  , Validity (..)
  , testHashFromList
  , unsafeTestBlockWithPayload
  )
import qualified Test.Util.TestBlock as TB
import "contra-tracer" Control.Tracer (nullTracer)

writeBlocks ::
  forall blk.
  ( ConvertRawHash blk
  , GetHeader blk
  , HasBinaryBlockInfo blk
  , Serialise blk
  ) =>
  FilePath ->
  ChunkNo ->
  NonEmpty blk ->
  IO (NonEmpty FilePath)
writeBlocks folder chunkNo blocks = do
  let rootFS = fpToHasFS folder
  blocksSizesAndChecksums <- withFile rootFS (fsPathChunkFile chunkNo) (WriteMode MustBeNew) $ \h -> traverse (\b -> (b,) <$> writeOneBlockOnly rootFS h b) blocks
  let offsets = NEL.map BlockOffset $ NEL.scanl (\acc (_, (s, _)) -> acc + s) 0 blocksSizesAndChecksums
      secondaryEntries =
        NEL.zipWith (\off (blk, (_, cs)) -> buildSecondaryEntry off cs blk) offsets blocksSizesAndChecksums
  Secondary.writeAllEntries rootFS chunkNo $ NEL.toList secondaryEntries
  case Primary.mk chunkNo $ map (fromIntegral . unBlockOffset) (NEL.init offsets) of
    Nothing -> error "Failed to build primary index"
    Just index -> Primary.write rootFS chunkNo index
  return $
    NEL.map (\t -> folder </> Text.unpack (getFileName t chunkNo)) $
      ChunkFile :| [PrimaryIndexFile, SecondaryIndexFile]

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

writeOneBlockOnly ::
  forall blk m h.
  (Serialise blk, Monad m) =>
  HasFS m h ->
  Handle h ->
  blk ->
  m (Word64, CRC)
writeOneBlockOnly hasFS currentChunkHandle = hPutAllCRC hasFS currentChunkHandle . CBOR.toLazyByteString . encode

instance Arbitrary SlotNo where
  arbitrary = SlotNo <$> arbitrary

instance Arbitrary Validity where
  arbitrary = (\p -> if p then Valid else Invalid) <$> arbitrary

genBlockHashPairs :: Int -> Gen [(TestBlock, TestHash)]
genBlockHashPairs n = do
  hashes <- genUniqueHashes n
  valids <- vectorOf n arbitrary
  slots <- map (SlotNo . fromIntegral) . List.sort . take n <$> shuffle [0 .. (3 * n)]
  return $
    zipWith3
      (\hash slot valid -> (unsafeTestBlockWithPayload hash slot valid (), hash))
      hashes
      slots
      valids

genUniqueHashes :: Int -> Gen [TestHash]
genUniqueHashes n = map (\h -> testHashFromList [fromIntegral h]) <$> shuffle [1 .. n]

prop_fullIterationOverChainHeadersRecapitulatesInput :: Property
prop_fullIterationOverChainHeadersRecapitulatesInput =
  noShrinking $ forAll (genBlockHashPairs 6) $ \blockHashPairs ->
    ioProperty $
      withTemp $ \tmp -> do
        let blocks = map fst blockHashPairs
        forM_ (zip [0 ..] $ Split.chunksOf 2 blocks) $ \(i, bs) -> writeBlocks tmp (ChunkNo i) (NEL.fromList bs)
        runtime <-
          let cfg =
                OnDemandConfig
                  { odcRemote =
                      RemoteStorageConfig{rscSrcUrl = getLocalUrl (1 + 2 ^ (16 :: Int)), rscDstDir = tmp}
                  , odcTracer = nullTracer
                  , odcChunkInfo = UniformChunkSize $ ChunkSize False 2
                  , odcHasFS = fpToHasFS tmp
                  , odcCodecConfig = TB.TestBlockCodecConfig
                  , odcCheckIntegrity = const True
                  , odcMaxCachedChunks = MaxCachedChunksCount 3
                  , odcPrefetchAhead = PrefetchChunksCount 0
                  }
           in OnDemand.newOnDemandRuntime cfg
        state <- readTVarIO $ odrState runtime
        atomically $
          writeTVar (odrState runtime) state{odsCachedChunks = Set.fromList $ map ChunkNo [0 .. 2]}
        iter <-
          OnDemand.onDemandIteratorFrom
            runtime
            GetHash
            (StreamFromExclusive GenesisPoint)
        (\hs -> hs === map snd blockHashPairs) <$> iteratorToList iter

useIterator :: Monad m => (b -> a -> a) -> a -> Iterator m blk b -> m a
useIterator combine acc0 iter = go iter $ pure acc0
 where
  go it acc = do
    maybeResult <- iteratorNext it
    case maybeResult of
      IteratorExhausted -> acc
      IteratorResult res -> go it (combine res <$> acc)

iteratorToList :: Monad m => Iterator m blk b -> m [b]
iteratorToList = fmap reverse . useIterator (:) []

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "iteration-test"

tests :: TestTree
tests =
  testGroup
    "iteration"
    [ testProperty
        "Basic iteration over headers is correct"
        prop_fullIterationOverChainHeadersRecapitulatesInput
    ]
