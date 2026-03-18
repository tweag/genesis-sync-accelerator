{-# OPTIONS_GHC -Wno-orphans #-}

-- | Typeclass instances for tests
module Test.GenesisSyncAccelerator.Orphans () where

import GenesisSyncAccelerator.Types
  ( MaxCachedChunksCount (..)
  , PrefetchChunksCount (..)
  )
import Numeric.Natural
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkInfo (..)
  , ChunkNo (..)
  , ChunkSize (..)
  )
import Test.GenesisSyncAccelerator.Types (PartialOnDemandConfig (..))
import Test.QuickCheck

instance Arbitrary ChunkSize where
  arbitrary = do
    n <- choose (1, 100)
    p <- arbitrary
    return $ ChunkSize{numRegularBlocks = n, chunkCanContainEBB = p}

instance Arbitrary ChunkInfo where
  arbitrary = do UniformChunkSize <$> arbitrary

-- | This picks a value between 0 and 10000
--
-- We don't pick larger values because we're not interested in testing overflow
-- due to huge epoch numbers and even huger slot numbers.
instance Arbitrary ChunkNo where
  arbitrary = ChunkNo <$> choose (0, 10000)
  shrink = genericShrink

instance Arbitrary PartialOnDemandConfig where
  arbitrary = do
    chunkInfo <- arbitrary
    integrity <- arbitrary
    maxChunks <- MaxCachedChunksCount <$> genNat 0 10
    numPrefetch <- PrefetchChunksCount <$> genNat 0 10
    return
      PartialOnDemandConfig
        { podcChunkInfo = chunkInfo
        , podcIntegrityConstant = integrity
        , podcMaxCachedChunks = maxChunks
        , podcPrefetchAhead = numPrefetch
        }

genNat :: Int -> Int -> Gen Natural
genNat low high = fromIntegral <$> choose (low, high)
