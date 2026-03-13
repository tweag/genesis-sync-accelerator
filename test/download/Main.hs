module Main (main) where

import qualified Test.GenesisSyncAccelerator.Download.Chunks
import qualified Test.GenesisSyncAccelerator.Download.RemoteTip
import Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "download"
    [ Test.GenesisSyncAccelerator.Download.Chunks.tests
    , Test.GenesisSyncAccelerator.Download.RemoteTip.tests
    ]
