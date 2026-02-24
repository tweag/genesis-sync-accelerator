{-# OPTIONS_GHC -Wno-orphans #-}

module Test.GenesisSyncAccelerator.Storage (tests) where

import qualified Data.Text as Text
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
import System.FS.API.Types (FsPath, fsPathToList)
import Test.QuickCheck
-- for Arbitrary Text
import Test.QuickCheck.Instances ()
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

-- | This picks an 'EpochNo' between 0 and 10000
--
-- We don't pick larger values because we're not interested in testing overflow
-- due to huge epoch numbers and even huger slot numbers.
instance Arbitrary ChunkNo where
  arbitrary = ChunkNo <$> choose (0, 10000)
  shrink = genericShrink

instance Arbitrary FileType where
  arbitrary =
    elements
      [ ChunkFile
      , PrimaryIndexFile
      , SecondaryIndexFile
      , EpochFile
      ]

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

getParseDBFileExpectation :: FileType -> ChunkNo -> (String, ChunkNo)
getParseDBFileExpectation ft cn = (Text.unpack $ toSuffix ft, cn)

prop_getFileName_is_compatible_with_parseDBFile_through_toSuffix :: FileType -> ChunkNo -> Property
prop_getFileName_is_compatible_with_parseDBFile_through_toSuffix ft cn =
  let fn = Text.unpack $ getFileName ft cn
   in parseDBFile fn === Just (getParseDBFileExpectation ft cn)

prop_getFileName_then_list__is_equivalent_to__renderFile_then_fsPathToList ::
  FileType -> ChunkNo -> Property
prop_getFileName_then_list__is_equivalent_to__renderFile_then_fsPathToList ft cn =
  [getFileName ft cn] === fsPathToList (renderFile (toSuffix ft) cn)

tests :: TestTree
tests =
  testGroup
    "ImmutableDB utilities"
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
    ]
