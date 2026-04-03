module GenesisSyncAccelerator.Util (fpToHasFS, getEntrySlot, getTopLevelConfig, getImmDbTip) where

import qualified Cardano.Tools.DBAnalyser.Block.Cardano as Cardano
import Cardano.Tools.DBAnalyser.HasAnalysis (mkProtocolInfo)
import Control.ResourceRegistry (runWithTempRegistry, withRegistry)
import Data.Proxy (Proxy (..))
import GHC.Conc (atomically)
import GenesisSyncAccelerator.RemoteStorage (RemoteTipInfo (..))
import GenesisSyncAccelerator.Types (StandardBlock, StandardTopLevelConfig)
import Ouroboros.Consensus.Block
  ( BlockNo (..)
  , ConvertRawHash (toRawHash)
  , SlotNo (..)
  , WithOrigin
  )
import Ouroboros.Consensus.Config (configCodec, configStorage)
import Ouroboros.Consensus.Node.InitStorage
  ( NodeInitStorage (nodeCheckIntegrity, nodeImmutableDbChunkInfo)
  )
import Ouroboros.Consensus.Node.ProtocolInfo (ProtocolInfo (..))
import Ouroboros.Consensus.Storage.ImmutableDB (ImmutableDbArgs (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmutableDB
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks (ChunkInfo)
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Layout as ChunkLayout
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Secondary (Entry (..))
import System.FS.API (HasFS, SomeHasFS (..))
import System.FS.IO (HandleIO, ioHasFS)
import System.FS.API.Types (MountPoint (MountPoint))

-- | Lift a filepath to a commonly used member of 'HasFS'.
fpToHasFS :: FilePath -> HasFS IO HandleIO
fpToHasFS = ioHasFS . MountPoint

getEntrySlot :: ChunkInfo -> Entry blk -> SlotNo
getEntrySlot ci = ChunkLayout.slotNoOfBlockOrEBB ci . blockOrEBB

-- | From the given config file, get a 'TopLevelConfig' for a standard Cardano block.
getTopLevelConfig :: FilePath -> IO StandardTopLevelConfig
getTopLevelConfig configFile = pInfoConfig <$> mkProtocolInfo (Cardano.CardanoBlockArgs configFile Nothing)

-- | Open the ImmutableDB at the given path and return its current tip.
getImmDbTip :: StandardTopLevelConfig -> FilePath -> IO (WithOrigin RemoteTipInfo)
getImmDbTip cfg immDBDir = withRegistry $ \registry ->
  ImmutableDB.withDB
    (ImmutableDB.openDB (immDBArgs registry) runWithTempRegistry)
    $ \immDB -> do
      tip <- atomically $ ImmutableDB.getTip immDB
      pure $ toRemoteTipInfo <$> tip
 where
  hasFS = fpToHasFS immDBDir
  storageCfg = configStorage cfg
  codecCfg = configCodec cfg
  immDBArgs registry =
    ImmutableDB.defaultArgs
      { immCheckIntegrity = nodeCheckIntegrity storageCfg
      , immChunkInfo = nodeImmutableDbChunkInfo storageCfg
      , immCodecConfig = codecCfg
      , immRegistry = registry
      , immHasFS = SomeHasFS hasFS
      }

toRemoteTipInfo :: ImmutableDB.Tip StandardBlock -> RemoteTipInfo
toRemoteTipInfo tip =
  RemoteTipInfo
    { rtiSlot = unSlotNo (ImmutableDB.tipSlotNo tip)
    , rtiBlockNo = unBlockNo (ImmutableDB.tipBlockNo tip)
    , rtiHashBytes = toRawHash (Proxy :: Proxy StandardBlock) (ImmutableDB.tipHash tip)
    }
