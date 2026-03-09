module ChunkUploader.Detection
  ( scanCompletedChunks
  ) where

import ChunkUploader.Types
  ( ChunkNo (..)
  , chunkExtensions
  , chunkFileName
  )
import Control.Monad (filterM)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import System.Directory (doesFileExist, getDirectoryContents, getFileSize)
import System.FilePath ((</>))
import Text.Read (readMaybe)

-- | Scan the immutable directory and return all completed chunk numbers.
--
-- A chunk N is considered complete when:
-- 1. Chunk N+1's .chunk file exists (proving N has been finalized)
-- 2. All three files (.chunk, .primary, .secondary) for N exist and are non-empty
--
-- The highest-numbered chunk is never returned, as it contains the tip and my still
-- be extended with additional blocks.
scanCompletedChunks :: FilePath -> IO [ChunkNo]
scanCompletedChunks dir = do
  entries <- getDirectoryContents dir
  let chunkNos = sort $ parseChunkNos entries
  case chunkNos of
    [] -> pure []
    -- Drop the latest chunk
    _ -> filterM isComplete (init chunkNos)
 where
  parseChunkNos :: [FilePath] -> [ChunkNo]
  parseChunkNos = mapMaybe parseChunkNo

  parseChunkNo :: FilePath -> Maybe ChunkNo
  parseChunkNo name =
    case break (== '.') name of
      (numStr, ".chunk") -> ChunkNo <$> readMaybe numStr
      _ -> Nothing

  isComplete :: ChunkNo -> IO Bool
  isComplete cn = and <$> mapM (fileExistsAndNonEmpty . (dir </>) . chunkFileName cn) chunkExtensions

  fileExistsAndNonEmpty :: FilePath -> IO Bool
  fileExistsAndNonEmpty fp = do
    exists <- doesFileExist fp
    if exists
      then (> 0) <$> getFileSize fp
      else pure False
