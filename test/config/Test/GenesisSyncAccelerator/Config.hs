{-# LANGUAGE OverloadedStrings #-}

module Test.GenesisSyncAccelerator.Config (tests) where

import Data.List (isInfixOf)
import Data.Yaml (ParseException, decodeEither', decodeThrow)
import GenesisSyncAccelerator.Config
  ( PartialConfig (..)
  , ResolvedOpts (..)
  , defaultConfig
  , resolveOpts
  )
import GenesisSyncAccelerator.Types
  ( MaxCachedChunksCount (..)
  , PrefetchChunksCount (..)
  , RetryCount (..)
  , TipRefreshInterval (..)
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "resolveOpts"
    [ testDefaults
    , testCliOverridesConfigFile
    , testConfigFileFillsGaps
    , testMissingRequired
    , testInvalidConfigAddr
    , testYamlParsing
    , testTrailingSlashStripping
    ]

-- | Required fields provided, everything else defaults.
testDefaults :: TestTree
testDefaults = testCase "defaults apply when only required fields are set" $ do
  let pc =
        mempty{pcNodeConfig = Just "/node.json", pcSrcUrl = Just "http://cdn/", pcCacheDir = Just "/cache"}
  case resolveOpts (pc <> defaultConfig) of
    Left err -> fail $ "unexpected error: " ++ err
    Right opts -> do
      resolvedAddr opts @?= (127, 0, 0, 1)
      resolvedPort opts @?= 3001
      resolvedMaxCachedChunks opts @?= MaxCachedChunksCount 10
      resolvedPrefetchAhead opts @?= PrefetchChunksCount 3
      resolvedTipRefreshInterval opts @?= TipRefreshInterval 600
      resolvedMaxRetries opts @?= RetryCount 5
      resolvedBaseDelay opts @?= 100000
      resolvedSrcUrl opts @?= "http://cdn"

-- | CLI values take precedence over config file values (left-biased merge).
testCliOverridesConfigFile :: TestTree
testCliOverridesConfigFile = testCase "CLI overrides config file values" $ do
  let cli =
        mempty
          { pcNodeConfig = Just "/cli-node.json"
          , pcSrcUrl = Just "http://cli-cdn"
          , pcPort = Just 4000
          , pcMaxCachedChunks = Just 20
          , pcCacheDir = Just "/cli-cache"
          , pcMaxRetries = Just (RetryCount 10)
          , pcBaseDelay = Just 50000
          }
      cf =
        mempty
          { pcNodeConfig = Just "/cf-node.json"
          , pcSrcUrl = Just "http://cf-cdn"
          , pcPort = Just 5000
          , pcMaxCachedChunks = Just 30
          , pcCacheDir = Just "/cf-cache"
          , pcMaxRetries = Just (RetryCount 15)
          , pcBaseDelay = Just 75000
          }
  case resolveOpts (cli <> cf <> defaultConfig) of
    Left err -> fail $ "unexpected error: " ++ err
    Right opts -> do
      resolvedNodeConfig opts @?= "/cli-node.json"
      resolvedSrcUrl opts @?= "http://cli-cdn"
      resolvedPort opts @?= 4000
      resolvedMaxCachedChunks opts @?= MaxCachedChunksCount 20
      resolvedCacheDir opts @?= "/cli-cache"
      resolvedMaxRetries opts @?= RetryCount 10
      resolvedBaseDelay opts @?= 50000

-- | Config file values are used when CLI omits them.
testConfigFileFillsGaps :: TestTree
testConfigFileFillsGaps = testCase "config file fills in when CLI is absent" $ do
  let cf =
        mempty
          { pcNodeConfig = Just "/cf-node.json"
          , pcSrcUrl = Just "http://cf-cdn"
          , pcPort = Just 7000
          , pcAddr = Just (10, 0, 0, 1)
          , pcPrefetchAhead = Just 5
          , pcCacheDir = Just "/cf-cache"
          }
  case resolveOpts (cf <> defaultConfig) of
    Left err -> fail $ "unexpected error: " ++ err
    Right opts -> do
      resolvedNodeConfig opts @?= "/cf-node.json"
      resolvedSrcUrl opts @?= "http://cf-cdn"
      resolvedPort opts @?= 7000
      resolvedAddr opts @?= (10, 0, 0, 1)
      resolvedPrefetchAhead opts @?= PrefetchChunksCount 5

-- | Missing required fields produce errors.
testMissingRequired :: TestTree
testMissingRequired =
  testGroup
    "missing required fields"
    [ testCase "missing node-config" $ do
        let pc = mempty{pcSrcUrl = Just "http://cdn", pcCacheDir = Just "/cache"}
        assertLeft "node-config" $ resolveOpts (pc <> defaultConfig)
    , testCase "missing rs-src-url" $ do
        let pc = mempty{pcNodeConfig = Just "/node.json", pcCacheDir = Just "/cache"}
        assertLeft "rs-src-url" $ resolveOpts (pc <> defaultConfig)
    , testCase "missing both" $ do
        let result = resolveOpts defaultConfig
        assertLeft "node-config" result
        assertLeft "rs-src-url" result
        assertLeft "cache-dir" result
    ]

-- | Invalid addr in config file YAML is caught during parsing.
testInvalidConfigAddr :: TestTree
testInvalidConfigAddr = testCase "invalid addr in YAML is a parse error" $ do
  let yaml = "addr: not.an.ip\nnode-config: /n.json\nrs-src-url: http://cdn\n"
  case decodeEither' yaml :: Either ParseException PartialConfig of
    Left _ -> pure () -- parse failure, as expected
    Right _ -> fail "expected YAML parse failure for invalid addr"

-- | YAML round-trip: a small config parses into the expected PartialConfig.
testYamlParsing :: TestTree
testYamlParsing = testCase "YAML parses into PartialConfig" $ do
  let yaml =
        "node-config: /path/to/node.json\n\
        \rs-src-url: http://cdn.example.com/chain\n\
        \port: 3002\n\
        \max-cached-chunks: 25\n\
        \addr: 192.168.1.1\n\
        \max-retries: 7\n\
        \base-delay: 200000\n"
  case decodeThrow yaml of
    Nothing -> fail "YAML parsing returned Nothing"
    Just pc -> do
      pcNodeConfig pc @?= Just "/path/to/node.json"
      pcSrcUrl pc @?= Just "http://cdn.example.com/chain"
      pcPort pc @?= Just 3002
      pcMaxCachedChunks pc @?= Just 25
      pcAddr pc @?= Just (192, 168, 1, 1)
      pcMaxRetries pc @?= Just (RetryCount 7)
      pcBaseDelay pc @?= Just 200000
      pcRtsFrequency pc @?= Nothing
      pcCacheDir pc @?= Nothing
      pcPrefetchAhead pc @?= Nothing
      pcTipRefreshInterval pc @?= Nothing

-- | Verify that trailing slashes are stripped from rs-src-url.
testTrailingSlashStripping :: TestTree
testTrailingSlashStripping = testCase "trailing slashes are stripped from rs-src-url" $ do
  let pc =
        mempty
          { pcNodeConfig = Just "/n.json"
          , pcSrcUrl = Just "http://cdn///"
          , pcCacheDir = Just "/cache"
          }
  case resolveOpts (pc <> defaultConfig) of
    Left err -> fail $ "unexpected error: " ++ err
    Right opts -> resolvedSrcUrl opts @?= "http://cdn"

-- Helpers

assertLeft :: String -> Either String a -> IO ()
assertLeft expected (Left err) =
  assertBool
    ("expected error containing " ++ show expected ++ ", got: " ++ err)
    (expected `isInfixOf` err)
assertLeft expected (Right _) =
  fail $ "expected Left containing " ++ show expected ++ ", got Right"
