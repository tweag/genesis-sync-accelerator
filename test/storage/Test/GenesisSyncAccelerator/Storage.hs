{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.Storage (tests) where

import Control.Monad (foldM, unless)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.Text as Text
import GenesisSyncAccelerator.OnDemand (deleteChunkFiles)
import GenesisSyncAccelerator.RemoteStorage (FileType (..), getFileName, toSuffix)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkNo (..)
  )
import Ouroboros.Consensus.Storage.ImmutableDB.Impl.Util
  ( fsPathChunkFile
  , fsPathPrimaryIndexFile
  , fsPathSecondaryIndexFile
  , parseDBFile
  , renderFile
  )
import System.Directory (doesFileExist)
import System.FS.API.Types (FsPath, MountPoint (MountPoint), fsPathToList)
import System.FS.IO (ioHasFS)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Orphans ()
import Test.GenesisSyncAccelerator.Utilities
  ( genSeveralChunkNumbers
  , getAllFilenamesForChunk
  , getCurrentFilenamesForChunk
  )
import Test.QuickCheck
import Test.QuickCheck.Instances ()
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

{-# ANN module "HLint: ignore Use camelCase" #-}

----------------------------- Generators and properties -----------------------------

-- | Sample uniformly at random from all known file types.
instance Arbitrary FileType where
  arbitrary =
    elements
      [ ChunkFile
      , PrimaryIndexFile
      , SecondaryIndexFile
      , EpochFile
      ]

-- | Generate names of files (associated with chunk numbers) to create and not to create, chunk to download, and test expectation.
--
-- This generates a few chunk numbers, then picks one of them as the "target chunk" for the test.
-- It then generates generates names of files associated with each chunk, and then an expectation
-- of which files should and should not exist after deleting the target chunk.
gen_target_chunk_setup_and_expectation_for_deleteChunkFiles ::
  Gen (ChunkNo, FilesSetup, FilesExpectation)
gen_target_chunk_setup_and_expectation_for_deleteChunkFiles = do
  -- We need at least one target chunk and one additional chunk for the test to be meaningful.
  -- Combine a limited domain with shuffling so that it's relatively cheap to ensure distinct elements.
  chunkNumbers <- genSeveralChunkNumbers
  -- We pick a target chunk number (for file deletion) and then construct expectations around it.
  targetChunk <- elements chunkNumbers
  let shouldNotExist = getCurrentFilenamesForChunk targetChunk
      shouldExist = filter (/= targetChunk) chunkNumbers >>= getCurrentFilenamesForChunk
      setup =
        -- Create all files corresponding to the randomly generated chunk numbers.
        FilesSetup
          { filesToCreate = shouldExist ++ shouldNotExist
          , filesToNotCreate = []
          }
      expectation =
        -- After deleting the target chunk, all files corresponding to the target chunk should not exist,
        -- and all other files should still exist.
        FilesExpectation
          { filesThatShouldExist = shouldExist
          , filesThatShouldNotExist = shouldNotExist
          }
  pure (targetChunk, setup, expectation)

-- | File naming functions from ouroboros-consensus behaves in a way which matches our `getFileName`.
--
-- Specifically, the given `getFsPath` function should produce an `FsPath` whose list representation
-- is a singleton list containing the same value as `getFileName`, when the same `FileType` and `ChunkNo` are used.
buildPropFsPathFileTypeIsCorrect :: FileType -> (ChunkNo -> FsPath) -> Property
buildPropFsPathFileTypeIsCorrect ft getFsPath =
  forAll arbitrary $ \cn ->
    let fsPathChunks = fsPathToList (getFsPath cn)
        observed = traverse (parseDBFile . Text.unpack) fsPathChunks
        expected = Just [getParseDBFileExpectation ft cn]
     in observed === expected

prop_fsPathChunkFileIsCorrect :: Property
prop_fsPathChunkFileIsCorrect =
  buildPropFsPathFileTypeIsCorrect ChunkFile fsPathChunkFile

prop_fsPathPrimaryIndexFileIsCorrect :: Property
prop_fsPathPrimaryIndexFileIsCorrect =
  buildPropFsPathFileTypeIsCorrect PrimaryIndexFile fsPathPrimaryIndexFile

prop_fsPathSecondaryIndexFileIsCorrect :: Property
prop_fsPathSecondaryIndexFileIsCorrect =
  buildPropFsPathFileTypeIsCorrect SecondaryIndexFile fsPathSecondaryIndexFile

-- | Our `getFileName` produces a filename which `parseDBFile` from ouroboros-consensus parses correctly.
--
-- Specifically, for a given file type and chunk number, `getFileName` produces a value which, when
-- parsed with `parseDBFile`, produces the same chunk number and a string corresponding to the file type.
prop_getFileName_is_compatible_with_parseDBFile_through_toSuffix :: FileType -> ChunkNo -> Property
prop_getFileName_is_compatible_with_parseDBFile_through_toSuffix ft cn =
  let fn = Text.unpack $ getFileName ft cn
   in parseDBFile fn === Just (getParseDBFileExpectation ft cn)

-- | `getFileName` yields the same value as `renderFile` when the latter is given the proper suffix.
prop_getFileName_then_list__is_equivalent_to__renderFile_then_fsPathToList ::
  FileType -> ChunkNo -> Property
prop_getFileName_then_list__is_equivalent_to__renderFile_then_fsPathToList ft cn =
  [getFileName ft cn] === fsPathToList (renderFile (toSuffix ft) cn)

-- | `deleteChunkFiles` should not fail if some or all of the files it's supposed to delete are missing.
prop_deleteChunkFiles_handles_missing_files :: Property
prop_deleteChunkFiles_handles_missing_files =
  forAll gen_ChunkNo_and_FilesSetup $ \(chunkNo, fnsSetup@FilesSetup{..}) ->
    ioProperty $
      withTemp $ \tmp -> do
        setupFiles tmp fnsSetup
        rmChunk tmp chunkNo
        -- No file should exist after deletion, regardless of its existence before deletion.
        nonExistences <-
          mapM (\fn -> not <$> doesFileExist (tmp </> fn)) (filesToCreate ++ filesToNotCreate)
        pure $ and nonExistences
 where
  -- Generate a chunk number to delete, and then create a subset of the files for that chunk.
  gen_ChunkNo_and_FilesSetup = do
    chunkNo <- arbitrary
    let fns = getCurrentFilenamesForChunk chunkNo
    toCreate <- sublistOf fns
    let toNotCreate = filter (`notElem` toCreate) fns
        setup = FilesSetup toCreate toNotCreate
    pure (chunkNo, setup)

-- | `deleteChunkFiles` should delete all files associated with the target chunk number.
prop_deleteChunkFiles_is_completely_sensitive_to_chunk_number :: Property
prop_deleteChunkFiles_is_completely_sensitive_to_chunk_number =
  forAll gen_target_chunk_setup_and_expectation_for_deleteChunkFiles $ \(targetChunk, setup, FilesExpectation{..}) ->
    ioProperty $
      withTemp $ \tmp -> do
        setupFiles tmp setup
        rmChunk tmp targetChunk
        -- Expected deletions should have all been done.
        and <$> mapM (fmap not . doesFileExist . (tmp </>)) filesThatShouldNotExist

-- | `deleteChunkFiles` should no file associated with any other chunk number.
prop_deleteChunkFiles_is_completely_specific_to_chunk_number :: Property
prop_deleteChunkFiles_is_completely_specific_to_chunk_number =
  forAll gen_target_chunk_setup_and_expectation_for_deleteChunkFiles $ \(targetChunk, setup, FilesExpectation{..}) ->
    ioProperty $
      withTemp $ \tmp -> do
        setupFiles tmp setup
        rmChunk tmp targetChunk
        -- Expected non-deletions should have all been preserved.
        and <$> mapM (doesFileExist . (tmp </>)) filesThatShouldExist

-- | The old `EpochFile` type's corresponding file, if present, is ignoreed by `deleteChunkFiles`.
prop_deleteChunkFiles_ignores_EpochFile :: ChunkNo -> Property
prop_deleteChunkFiles_ignores_EpochFile chunkNo =
  ioProperty $
    withTemp $ \tmp -> do
      let fns = getAllFilenamesForChunk chunkNo
      setupFiles tmp (FilesSetup fns [])
      rmChunk tmp chunkNo
      doesFileExist (tmp </> Text.unpack (getFileName EpochFile chunkNo))

----------------------------- Helper functions and types -----------------------------

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "storage-test"

-- Call `deleteChunkFiles`, handling the mapping from `FilePath` to a `HasFS` type.
rmChunk :: FilePath -> ChunkNo -> IO ()
rmChunk folder = deleteChunkFiles (ioHasFS $ MountPoint folder)

-- Get the expectation (modulo `Just` wrapping) of parsing a filename with `parseDBFile` (consensus).
getParseDBFileExpectation :: FileType -> ChunkNo -> (String, ChunkNo)
getParseDBFileExpectation ft cn = (Text.unpack $ toSuffix ft, cn)

-- Create certain files in the given directory, asserting they exist and that others don't.
setupFiles :: FilePath -> FilesSetup -> IO ()
setupFiles tmp FilesSetup{..} = do
  let makeFile fn = writeFile fp "filler text" >> pure fp
       where
        fp = tmp </> fn
      nonExtantPaths = map (tmp </>) filesToNotCreate
  extantPaths <- foldM (\acc fn -> (: acc) <$> makeFile fn) [] filesToCreate
  pretestPositive <- and <$> mapM doesFileExist extantPaths
  pretestNegative <- and <$> mapM (fmap not . doesFileExist) nonExtantPaths
  unless pretestPositive $
    error "Failed to set up test: some files that were supposed to be created were not."
  unless pretestNegative $
    error "Failed to set up test: some files that were supposed to not be created were."

-- | A bundle of which files to create and not to create for a test.
data FilesSetup = FilesSetup
  { filesToCreate :: [String]
  , filesToNotCreate :: [String]
  }
  deriving (Eq, Show)

-- | Specification of files which should exist or not exist after calling a function under test.
data FilesExpectation = FilesExpectation
  { filesThatShouldExist :: [String]
  , filesThatShouldNotExist :: [String]
  }
  deriving (Eq, Show)

----------------------------- Property aggregation -----------------------------
tests :: TestTree
tests =
  testGroup
    "Storage-related utilities"
    [ testProperty
        "getFileName is compatible with parseDBFile through toSuffix"
        prop_getFileName_is_compatible_with_parseDBFile_through_toSuffix
    , testProperty
        "fsPathChunkFile parses as ChunkFile"
        prop_fsPathChunkFileIsCorrect
    , testProperty
        "fsPathPrimaryIndexFile parses as PrimaryIndexFile"
        prop_fsPathPrimaryIndexFileIsCorrect
    , testProperty
        "fsPathSecondaryIndexFile parses as SecondaryIndexFile"
        prop_fsPathSecondaryIndexFileIsCorrect
    , testProperty
        "getFileName then list is equivalent to renderFile then fsPathToList"
        prop_getFileName_then_list__is_equivalent_to__renderFile_then_fsPathToList
    , testProperty
        "deleteChunkFiles handles missing files gracefully"
        prop_deleteChunkFiles_handles_missing_files
    , testProperty
        "deleteChunkFiles is completely sensitive to the chunk number"
        prop_deleteChunkFiles_is_completely_sensitive_to_chunk_number
    , testProperty
        "deleteChunkFiles is completely specific to the chunk number"
        prop_deleteChunkFiles_is_completely_specific_to_chunk_number
    , testProperty
        "deleteChunkFiles ignores EpochFile"
        prop_deleteChunkFiles_ignores_EpochFile
    ]
