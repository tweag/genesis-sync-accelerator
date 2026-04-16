module Main (main) where

import qualified Test.GenesisSyncAccelerator.Config
import Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "config"
    [ Test.GenesisSyncAccelerator.Config.tests
    ]
