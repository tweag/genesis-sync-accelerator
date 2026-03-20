module Test.GenesisSyncAccelerator.Types
  ( ConfigFile (..)
  , TmpDir (..)
  , PartialOnDemandConfig (..)
  , ClientFolder (..)
  , ServerFolder (..)
  ) where

import GenesisSyncAccelerator.Types (MaxCachedChunksCount, PrefetchChunksCount)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkInfo)

newtype ConfigFile = ConfigFile {unConfigFile :: FilePath} deriving Show

newtype TmpDir = TmpDir {unTmpDir :: FilePath} deriving Show

newtype ClientFolder = ClientFolder {unClientFolder :: FilePath} deriving (Eq, Show)

newtype ServerFolder = ServerFolder {unServerFolder :: FilePath} deriving (Eq, Show)

data PartialOnDemandConfig = PartialOnDemandConfig
  { podcChunkInfo :: ChunkInfo
  , podcIntegrityConstant :: Bool
  , podcMaxCachedChunks :: MaxCachedChunksCount
  , podcPrefetchAhead :: PrefetchChunksCount
  }
  deriving Show
