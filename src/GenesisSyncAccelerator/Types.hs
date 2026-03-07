module GenesisSyncAccelerator.Types (HostAddr, StandardBlock, StandardTopLevelConfig) where

import Data.Word (Word8)
import Ouroboros.Consensus.Cardano.Block (CardanoBlock)
import Ouroboros.Consensus.Config (TopLevelConfig)
import Ouroboros.Consensus.Protocol.TPraos (StandardCrypto)

-- | A representation of a IPv4 address
type HostAddr = (Word8, Word8, Word8, Word8)

-- | The block type typically used across the codebase
type StandardBlock = CardanoBlock StandardCrypto

-- | The type of main configuration object used across the codebase
type StandardTopLevelConfig = TopLevelConfig StandardBlock
