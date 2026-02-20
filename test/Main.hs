module Main (main) where

import qualified Test.GenesisSyncAccelerator.Storage
import Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "storage"
    [ Test.GenesisSyncAccelerator.Storage.tests
    ]
