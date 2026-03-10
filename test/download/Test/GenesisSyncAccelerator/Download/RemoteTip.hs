{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.GenesisSyncAccelerator.Download.RemoteTip (tests) where

import Control.Tracer (Tracer (..))
import Data.Aeson (encode)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.List as List
import GenesisSyncAccelerator.RemoteStorage
  ( RemoteStorageConfig (..)
  , RemoteTipInfo (..)
  , TraceRemoteStorageEvent (..)
  , fetchTipInfo
  )
import Network.HTTP.Types (status200)
import Network.Wai (responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}

----------------------------- Test cases -----------------------------

-- fetchTipInfo should be able to parse tip.json served over HTTP.
test_fetchTipInfo_parses_json :: IO ()
test_fetchTipInfo_parses_json = do
  let tipInfo =
        RemoteTipInfo
          { rtiSlot = 7
          , rtiBlockNo = 42
          , rtiHashBytes = "0123456789abcdef"
          }
      app _ respond = respond $ responseLBS status200 [("Content-Type", "application/json")] (encode tipInfo)

  testWithApplication (pure app) $ \port -> do
    let cfg = RemoteStorageConfig{rscSrcUrl = "http://localhost:" ++ show port, rscDstDir = "."}
    eventsRef <- newIORef []
    let tracer = Tracer $ \ev -> atomicModifyIORef' eventsRef (\evs -> (evs ++ [ev], ()))
    result <- fetchTipInfo tracer cfg
    assertEqual "Fetched tip info matches served JSON" (Right tipInfo) result

    events <- readIORef eventsRef
    let isDownloadStart = \case
          TraceDownloadStart url -> "tip.json" `List.isSuffixOf` url
          _ -> False
    assertEqual "TraceDownloadStart emitted for tip.json" True (any isDownloadStart events)

----------------------------- Test aggregation -----------------------------

tests :: TestTree
tests =
  testGroup
    "remote tip integration"
    [ testCase "fetchTipInfo parses tip.json served over HTTP" test_fetchTipInfo_parses_json
    ]
