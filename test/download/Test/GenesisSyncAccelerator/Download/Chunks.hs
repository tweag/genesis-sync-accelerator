{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.Download.Chunks (tests) where

import Control.Monad (filterM, foldM, forM_, unless)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (comparing)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import GenesisSyncAccelerator.RemoteStorage
  ( FileType (..)
  , TraceDownloadFailure (..)
  , TraceRemoteStorageEvent (..)
  , downloadChunk
  , getFileName
  , newRemoteStorageEnv
  )
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
  ( ChunkNo (..)
  )
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import Test.GenesisSyncAccelerator.Orphans ()
import Test.GenesisSyncAccelerator.Utilities
  ( allFileTypes
  , currentFileTypes
  , genSeveralChunkNumbers
  , getCurrentFilenamesForChunk
  )
import Test.QuickCheck
import Test.QuickCheck.Instances ()
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import "contra-tracer" Control.Tracer (Tracer (..), nullTracer)

{-# ANN module "HLint: ignore Use camelCase" #-}

----------------------------- Generators and properties -----------------------------

-- There should be exactly one file for each of the current file types, nothing more and nothing less.
prop_downloadChunk_downloads_files_as_expected_when_available :: Property
prop_downloadChunk_downloads_files_as_expected_when_available =
  forAll gen_target_chunk_and_file_kernels $ \(targetChunk, fileKernels) ->
    ioProperty $
      withTemp $ \tmp -> do
        -- Establish the files on the server side, and check the precondition that no file is
        -- already present on the client side.
        setup@TestFolderSetup{..} <- setupFilesAndFolders tmp fileKernels
        initialTargetFolderContents <- listDirectory clientTmpdir
        case initialTargetFolderContents of
          -- No file should yet be present in the target folder.
          [] -> do
            unsafeDownloadChunk nullTracer setup targetChunk
            posthocTargetFolderContents <- listDirectory clientTmpdir
            -- After the download, each of the current file types should be represented for the
            -- target chunk by a file; there should be no other content in the target folder.
            pure $ List.sort posthocTargetFolderContents === List.sort (getCurrentFilenamesForChunk targetChunk)
          -- The presence of any file in the target folder invalidates the test precondition.
          contents -> do
            error $ "The target folder is nonempty: " ++ show contents
 where
  -- Choose a target chunk and pair it with each current file type and the ServerSide designation.
  gen_target_chunk_and_file_kernels :: Gen (ChunkNo, [FileKernel])
  gen_target_chunk_and_file_kernels = do
    allChunkNumbers <- genSeveralChunkNumbers
    targetChunk <- elements allChunkNumbers
    return (targetChunk, [(ServerSide, t, c) | t <- currentFileTypes, c <- allChunkNumbers])

-- For any requested file not available and not present locally, an error should be traced.
prop_downloadChunk_traces_errors_as_expected_when_files_are_unavailable :: Property
prop_downloadChunk_traces_errors_as_expected_when_files_are_unavailable =
  forAll gen_target_chunk_and_file_kernels_and_missing_file_types $ \(targetChunk, fileKernels, expectedMissingFileTypes) ->
    let httpErrorCode = 404
        expectedErrors = map (\t -> TraceDownloadError (nameFile t targetChunk) httpErrorCode) expectedMissingFileTypes
        isExpectedLogLine l =
          "TraceDownloadFailure (TraceDownloadError " `List.isPrefixOf` l
            && (" " ++ show httpErrorCode ++ ")") `List.isSuffixOf` l
     in ioProperty $
          withTemp $ \tmp -> do
            let logfile = tmp </> "log.txt"
                tracer = tracerToFile logfile
            setup@TestFolderSetup{..} <- setupFilesAndFolders tmp fileKernels
            initialTargetFolderContents <- listDirectory clientTmpdir
            case initialTargetFolderContents of
              [] -> do
                -- Precondition passes; call the function under test then check that
                -- the logfile contains all the expected error messages.
                unsafeDownloadChunk tracer setup targetChunk
                logLines <- lines . Text.unpack <$> TIO.readFile logfile
                pure $
                  List.sort (filter isExpectedLogLine logLines)
                    === List.sort (map (show . TraceDownloadFailure) expectedErrors)
              contents -> do
                error $ "The target folder is nonempty: " ++ show contents
 where
  -- Choose a chunk to download from among several for which files will be created.
  -- Deliberately do not create at least one of the files for the chosen chunk,
  -- and keep track of for which file types this is the case (i.e., that the file
  -- to download for that type for the chosen chunk is unavailable and not already there locally).
  gen_target_chunk_and_file_kernels_and_missing_file_types :: Gen (ChunkNo, [FileKernel], [FileType])
  gen_target_chunk_and_file_kernels_and_missing_file_types = do
    chunks <- genSeveralChunkNumbers
    targetChunk <- elements chunks
    missingFileTypes <- sublistOf currentFileTypes
    let kernels =
          [ (ServerSide, ft, cn)
          | ft <- currentFileTypes
          , cn <- chunks
          , not $ ft `elem` missingFileTypes && cn == targetChunk
          ]
    return (targetChunk, kernels, missingFileTypes)

-- Missing files are downloaded while existing files are overwritten.
prop_downloadChunk_correctly_handles_mixed_local_preexistence_of_files :: Property
prop_downloadChunk_correctly_handles_mixed_local_preexistence_of_files =
  forAll gen_target_chunk_and_file_kernels $ \(targetChunk, fileKernels) ->
    let expectedPreDownloadFileNames =
          foldr
            (\(s, t, c) acc -> if s == ClientSide then Map.insert (t, c) (nameFile t c) acc else acc)
            mempty
            fileKernels
        allTargetChunkFileNames = List.sort $ getCurrentFilenamesForChunk targetChunk
     in ioProperty $
          withTemp $ \tmp -> do
            setup@TestFolderSetup{..} <- setupFilesAndFolders tmp fileKernels
            preDownloadClientSideFileNames <- List.sort <$> listDirectory clientTmpdir
            preDownloadServerSideFileNames <- listDirectory serverTmpdir
            unless
              (preDownloadClientSideFileNames == List.sort (Map.elems expectedPreDownloadFileNames))
              $ error
              $ "Pre-download contents ("
                ++ show preDownloadClientSideFileNames
                ++ ") don't match expectation ("
                ++ show (List.sort (Map.elems expectedPreDownloadFileNames))
                ++ ")"
            preDownloadContentErrors <-
              catMaybes
                <$> mapM (\fn -> hasContent ClientSide $ clientTmpdir </> fn) preDownloadClientSideFileNames
            case preDownloadContentErrors of
              [] -> do
                -- Run the function under test, then check that the list of files present
                -- in the target folder is exactly as expected.
                unsafeDownloadChunk nullTracer setup targetChunk
                filesAfterDownload <- List.sort <$> listDirectory clientTmpdir
                if filesAfterDownload /= allTargetChunkFileNames
                  then
                    pure $
                      counterexample
                        ( "After download, observed filenames ("
                            ++ show filesAfterDownload
                            ++ ") don't match expected filenames ("
                            ++ show allTargetChunkFileNames
                        )
                        False
                  else do
                    -- Check that the content of each file present before the download
                    -- has been replaced by the server-side content if the file was
                    -- present on the server side, otherwise that the content remained
                    -- the same, and that content of the downloaded files matches expectation.
                    let (expDynamic, expStatic) = List.partition (`elem` preDownloadServerSideFileNames) filesAfterDownload
                    errorsFromExpectationOfStasis <-
                      catMaybes
                        <$> mapM (\fn -> hasContent ClientSide $ clientTmpdir </> fn) expStatic
                    errorsFromExpectationOfDownload <-
                      catMaybes
                        <$> mapM (\fn -> hasContent ServerSide $ clientTmpdir </> fn) expDynamic
                    pure $ case errorsFromExpectationOfStasis ++ errorsFromExpectationOfDownload of
                      [] -> property True
                      errors ->
                        counterexample ("Violation(s) of post-download file content expectations: " ++ show errors) False
              errors -> error $ "Violation(s) of pre-download file content expectations: " ++ show errors
 where
  -- Generate a chunk to download and file kernels such that, for the chosen chunk, only some of
  -- of the file types will already be present locally. At least all of the file types missing
  -- locally will be present on the server side of the download connection, along with 0 or more
  -- of the files for the types already present locally for the chosen chunk.
  gen_target_chunk_and_file_kernels :: Gen (ChunkNo, [FileKernel])
  gen_target_chunk_and_file_kernels = do
    targetChunk <- arbitrary
    presentClientSideFileTypes <- sublistOf currentFileTypes
    let absentClientSideFileTypes = filter (`notElem` presentClientSideFileTypes) currentFileTypes
    presentServerSideFileTypes <-
      List.nub . (++ absentClientSideFileTypes) <$> sublistOf currentFileTypes
    return
      ( targetChunk
      , [ (s, t, targetChunk)
        | (s, t) <-
            map (ServerSide,) presentServerSideFileTypes ++ map (ClientSide,) presentClientSideFileTypes
        ]
      )
  -- Check that the file at the given path has the content expected for the given
  -- side of the connection, giving an error messsage about why, if not.
  hasContent :: ConnectionSide -> FilePath -> IO (Maybe String)
  hasContent side file = do
    obsContent <- Text.unpack <$> TIO.readFile file
    pure $
      if obsContent == expContent
        then Nothing
        else
          Just $ "For file " ++ file ++ ", expected '" ++ expContent ++ "' but got '" ++ obsContent ++ "'"
   where
    expContent = getTmpfileContent side

----------------------------- Helper functions and types -----------------------------

withTemp :: forall m a. (MonadIO m, MonadMask m) => (FilePath -> m a) -> m a
withTemp = Temp.withSystemTempDirectory "download-test"

-- Trace values of given type to given file by appending the 'show' representation with a newline.
tracerToFile :: Show a => FilePath -> Tracer IO a
tracerToFile f = Tracer (\a -> appendFile f (show a ++ "\n"))

getTmpfileContent :: ConnectionSide -> String
getTmpfileContent = ("file on " ++) . show

nameFile :: FileType -> ChunkNo -> String
nameFile ft cn = Text.unpack $ getFileName ft cn

-- | Download files from a local HTTP file server.
--
-- Run a local HTTP file server of the contents of a temporary subdirectory, and then
-- call into `downloadChunk` pointing to that server as the source and another temporary
-- subdirectory as the destination.
unsafeDownloadChunk ::
  Tracer IO TraceRemoteStorageEvent ->
  TestFolderSetup ->
  ChunkNo ->
  IO ()
unsafeDownloadChunk tracer TestFolderSetup{..} targetChunk =
  testWithApplication (pure $ staticApp $ defaultFileServerSettings serverTmpdir) $
    \port -> do
      storageEnv <- newRemoteStorageEnv ("http://localhost:" ++ show port) clientTmpdir
      either (error . show) (const ()) <$> downloadChunk tracer storageEnv targetChunk

-- Within the given folder, create the filepaths specified by the given "kernel"s.
setupFilesAndFolders :: FilePath -> [FileKernel] -> IO TestFolderSetup
setupFilesAndFolders tmpRoot fileKernels = do
  let getFolder side = tmpRoot </> show side
      mkfile :: FileKernel -> IO FilePath
      mkfile (s, t, c) = let fp = getFolder s </> nameFile t c in writeFile fp (getTmpfileContent s) >> pure fp
      serverTmpdir = getFolder ServerSide
      clientTmpdir = getFolder ClientSide
  forM_ [serverTmpdir, clientTmpdir] (False `createDirectoryIfMissing`)
  filepaths <- foldM (\acc k -> (: acc) <$> mkfile k) [] fileKernels
  missingFiles <- filterM (fmap not . doesFileExist) filepaths
  case missingFiles of
    [] -> pure ()
    missing -> error $ "Not all files to create have been created; missing: " ++ show missing
  return $ TestFolderSetup{serverTmpdir = serverTmpdir, clientTmpdir = clientTmpdir}

-- Either the server or client side of a connection over which files are donwnloaded.
data ConnectionSide = ServerSide | ClientSide deriving (Show, Eq, Ord)

-- Determines subfolder within a temporary directory, and file name.
type FileKernel = (ConnectionSide, FileType, ChunkNo)

data TestFolderSetup = TestFolderSetup
  { serverTmpdir :: FilePath
  , clientTmpdir :: FilePath
  }
  deriving (Show, Eq)

-- Order file type values by the position of the value in the listing of all file types.
instance Ord FileType where
  compare = comparing index
   where
    index t = fromMaybe (error $ "Failed to lookup index of type: " ++ show t) $ List.elemIndex t allFileTypes

----------------------------- Property aggregation -----------------------------
tests :: TestTree
tests =
  testGroup
    "Download-related utilities"
    [ testProperty
        "downloadChunk downloads requested files as expected when available"
        prop_downloadChunk_downloads_files_as_expected_when_available
    , testProperty
        "downloadChunk traces download errors correctly"
        prop_downloadChunk_traces_errors_as_expected_when_files_are_unavailable
    , testProperty
        "downloadChunk correctly handles mixed local preexistence of files"
        prop_downloadChunk_correctly_handles_mixed_local_preexistence_of_files
    ]
