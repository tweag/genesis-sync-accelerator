{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module ChunkUploader.Types
  ( UploaderConfig (..)
  , ChunkNo (..)
  , TraceUploaderEvent (..)
  , chunkFileName
  , chunkExtensions
  ) where

import Data.Text (Text)
import Data.Word (Word64)

-- | Newtype for chunk numbers (vendored to avoid dependence on ouroboros-consensus types)
newtype ChunkNo = ChunkNo {unChunkNo :: Word64}
  deriving stock (Eq, Ord, Show)
  deriving newtype (Num, Enum, Real, Integral)

-- | Configuration for the chunk uploader.
data UploaderConfig = UploaderConfig
  { ucImmutableDir :: !FilePath
  -- ^ Path to the ImmutableDB immutable/ directory.
  , ucS3Bucket :: !Text
  -- ^ S3 bucket name.
  , ucS3Prefix :: !Text
  -- ^ Key prefix for uploaded objects (e.g. "immutable/").
  , ucS3Endpoint :: !(Maybe Text)
  -- ^ Custom S3 endpoint URL as @scheme://host[:port]@ for R2/MinIO/etc.
  -- Path components are not supported (Amazonka's 'setEndpoint' only takes host\/port).
  , ucS3Region :: !Text
  -- ^ AWS region (see provider documentation).
  , ucPollInterval :: !Int
  -- ^ Seconds between directory scans.
  , ucStateFile :: !(Maybe FilePath)
  -- ^ Optional explicit path for the state file.
  }
  deriving stock Show

-- | Events traced by the chunk uploader.
data TraceUploaderEvent
  = TraceScanStart
  | TraceScanComplete ![ChunkNo]
  | TraceUploadStart !ChunkNo !String
  | TraceUploadSuccess !ChunkNo !String
  | TraceUploadFailure !ChunkNo !String !String
  | TraceUploadRetry !ChunkNo !Int
  | TraceStateLoaded !(Maybe ChunkNo)
  | TraceStateSaved !ChunkNo
  deriving stock (Eq, Show)

-- | Build the filename for a chunk with a given extension.
--
-- >>> chunkFileName (ChunkNo 42) ".chunk"
-- "00042.chunk"
chunkFileName :: ChunkNo -> String -> FilePath
chunkFileName (ChunkNo n) ext =
  let s = show n
      padded = replicate (5 - length s) '0' ++ s
   in padded ++ ext

-- | The three file extensions that make up a complete chunk triplet.
chunkExtensions :: [String]
chunkExtensions = [".chunk", ".primary", ".secondary"]
