module Main (main) where

import qualified Test.GenesisSyncAccelerator.OnDemandRuntime
import Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "on-demand"
    [ Test.GenesisSyncAccelerator.OnDemandRuntime.tests
    ]
