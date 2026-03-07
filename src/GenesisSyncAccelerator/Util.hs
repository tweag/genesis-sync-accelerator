module GenesisSyncAccelerator.Util (fpToHasFS, getTopLevelConfig) where

import qualified Cardano.Tools.DBAnalyser.Block.Cardano as Cardano
import Cardano.Tools.DBAnalyser.HasAnalysis (mkProtocolInfo)
import GenesisSyncAccelerator.Types (StandardTopLevelConfig)
import Ouroboros.Consensus.Node.ProtocolInfo (ProtocolInfo (..))
import System.FS.API (HasFS)
import System.FS.API.Types (MountPoint (MountPoint))
import System.FS.IO (HandleIO, ioHasFS)

-- | Lift a filepath to a commonly used member of 'HasFS'.
fpToHasFS :: FilePath -> HasFS IO HandleIO
fpToHasFS = ioHasFS . MountPoint

-- | From the given config file, get a 'TopLevelConfig' for a standard Cardano block.
getTopLevelConfig :: FilePath -> IO StandardTopLevelConfig
getTopLevelConfig configFile = pInfoConfig <$> mkProtocolInfo (Cardano.CardanoBlockArgs configFile Nothing)
