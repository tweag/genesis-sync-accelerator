{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Domain-specific type wrappers and aliases
module GenesisSyncAccelerator.Types
  ( HostAddr
  , MaxCachedChunksCount (..)
  , PrefetchChunksCount (..)
  , RetryBaseDelay
  , RetryCount (..)
  , StandardBlock
  , StandardTopLevelConfig
  , TipRefreshInterval (..)
  , asRetryBaseDelay
  , getRetryDelay
  ) where

import Data.Aeson (FromJSON)
import Data.Word (Word8)
import Numeric.Natural
import Ouroboros.Consensus.Cardano.Block (CardanoBlock)
import Ouroboros.Consensus.Config (TopLevelConfig)
import Ouroboros.Consensus.Protocol.TPraos (StandardCrypto)

-- | A representation of a IPv4 address
type HostAddr = (Word8, Word8, Word8, Word8)

-- | Specification of maximum number of chunks to keep in cache
newtype MaxCachedChunksCount = MaxCachedChunksCount Natural
  deriving (Eq, Show)

-- | How many chunks ahead of the current to fetch in advance
newtype PrefetchChunksCount = PrefetchChunksCount Natural
  deriving (Eq, Show)

-- | The base delay (for exponential backoff) for retrying a failed operation
newtype RetryBaseDelay = RetryBaseDelay {unRetryBaseDelay :: Natural}
  deriving (Eq, FromJSON, Ord, Show)

asRetryBaseDelay :: Natural -> RetryBaseDelay
asRetryBaseDelay = RetryBaseDelay

getRetryDelay :: RetryBaseDelay -> RetryCount -> Natural
getRetryDelay (RetryBaseDelay base) (RetryCount n) = base * (2 ^ n)

-- | Count of number of retries for some operation
newtype RetryCount = RetryCount {unRetryCount :: Natural}
  deriving (Eq, FromJSON, Ord, Read, Show)

-- | The block type typically used across the codebase
type StandardBlock = CardanoBlock StandardCrypto

-- | The type of main configuration object used across the codebase
type StandardTopLevelConfig = TopLevelConfig StandardBlock

-- | How often to refresh the tip from the CDN, in seconds.
newtype TipRefreshInterval = TipRefreshInterval Natural
  deriving (Eq, Show)
