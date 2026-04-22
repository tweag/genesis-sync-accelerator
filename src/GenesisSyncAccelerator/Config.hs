{-# LANGUAGE OverloadedStrings #-}

module GenesisSyncAccelerator.Config
  ( PartialConfig (..)
  , RTSFrequency (..)
  , ResolvedOpts (..)
  , defaultConfig
  , resolveOpts
  , showAddr
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), withObject, (.:?))
import Data.Aeson.Types (Parser)
import Data.List (dropWhileEnd, intercalate, sort)
import Data.Maybe (fromMaybe, isNothing)
import GenesisSyncAccelerator.Parsers (parseAddr)
import GenesisSyncAccelerator.Types
  ( HostAddr
  , MaxCachedChunksCount (..)
  , PrefetchChunksCount (..)
  , RetryBaseDelay
  , RetryCount (..)
  , TipRefreshInterval (..)
  , asRetryBaseDelay
  )
import qualified Network.Socket as Socket
import Numeric.Natural (Natural)

-- | Resolved options after merging CLI and config file.
data ResolvedOpts = ResolvedOpts
  { resolvedAddr :: HostAddr
  , resolvedPort :: Socket.PortNumber
  , resolvedNodeConfig :: FilePath
  , resolvedRtsFrequency :: RTSFrequency
  , resolvedCacheDir :: FilePath
  , resolvedSrcUrl :: String
  , resolvedMaxCachedChunks :: MaxCachedChunksCount
  , resolvedPrefetchAhead :: PrefetchChunksCount
  , resolvedTipRefreshInterval :: TipRefreshInterval
  , resolvedMaxRetries :: RetryCount
  , resolvedBaseDelay :: RetryBaseDelay
  }

newtype RTSFrequency = RTSFrequency {unRTSFrequency :: Int}

-- | Partial configuration. Used for both CLI options and the config file.
-- All fields are optional; merging uses left-biased @('<>')@.
data PartialConfig = PartialConfig
  { pcAddr :: Maybe HostAddr
  , pcPort :: Maybe Socket.PortNumber
  , pcNodeConfig :: Maybe FilePath
  , pcRtsFrequency :: Maybe Int
  , pcCacheDir :: Maybe FilePath
  , pcSrcUrl :: Maybe String
  , pcMaxCachedChunks :: Maybe Natural
  , pcPrefetchAhead :: Maybe Natural
  , pcTipRefreshInterval :: Maybe Natural
  , pcMaxRetries :: Maybe RetryCount
  , pcBaseDelay :: Maybe Natural
  }

-- | Left-biased merge: the first argument wins when both sides are 'Just'.
instance Semigroup PartialConfig where
  a <> b =
    PartialConfig
      { pcAddr = pcAddr a <|> pcAddr b
      , pcPort = pcPort a <|> pcPort b
      , pcNodeConfig = pcNodeConfig a <|> pcNodeConfig b
      , pcRtsFrequency = pcRtsFrequency a <|> pcRtsFrequency b
      , pcCacheDir = pcCacheDir a <|> pcCacheDir b
      , pcSrcUrl = pcSrcUrl a <|> pcSrcUrl b
      , pcMaxCachedChunks = pcMaxCachedChunks a <|> pcMaxCachedChunks b
      , pcPrefetchAhead = pcPrefetchAhead a <|> pcPrefetchAhead b
      , pcTipRefreshInterval = pcTipRefreshInterval a <|> pcTipRefreshInterval b
      , pcMaxRetries = pcMaxRetries a <|> pcMaxRetries b
      , pcBaseDelay = pcBaseDelay a <|> pcBaseDelay b
      }

instance Monoid PartialConfig where
  mempty =
    PartialConfig
      { pcAddr = Nothing
      , pcPort = Nothing
      , pcNodeConfig = Nothing
      , pcRtsFrequency = Nothing
      , pcCacheDir = Nothing
      , pcSrcUrl = Nothing
      , pcMaxCachedChunks = Nothing
      , pcPrefetchAhead = Nothing
      , pcTipRefreshInterval = Nothing
      , pcMaxRetries = Nothing
      , pcBaseDelay = Nothing
      }

-- | Default values for all optional configuration fields.
-- Does not include 'pcCacheDir' since the XDG default requires IO;
-- the caller should set it before passing to 'resolveOpts'.
defaultConfig :: PartialConfig
defaultConfig =
  mempty
    { pcAddr = Just (127, 0, 0, 1)
    , pcPort = Just 3001
    , pcRtsFrequency = Just 1000
    , pcMaxCachedChunks = Just 10
    , pcPrefetchAhead = Just 3
    , pcTipRefreshInterval = Just 600
    , pcMaxRetries = Just (RetryCount 5)
    , pcBaseDelay = Just 100000
    }

instance FromJSON PartialConfig where
  parseJSON = withObject "PartialConfig" $ \o -> do
    addr <- traverse parseAddrJSON =<< o .:? "addr"
    port <- fmap fromIntegral <$> (o .:? "port" :: Parser (Maybe Int))
    PartialConfig addr port
      <$> o .:? "node-config"
      <*> o .:? "rts-frequency"
      <*> o .:? "cache-dir"
      <*> o .:? "rs-src-url"
      <*> o .:? "max-cached-chunks"
      <*> o .:? "prefetch-ahead"
      <*> o .:? "tip-refresh-interval"
      <*> o .:? "max-retries"
      <*> o .:? "base-delay"
   where
    parseAddrJSON s = case parseAddr s of
      Right a -> pure a
      Left err -> fail $ "Invalid addr: " ++ err

-- | Unwrap a fully-merged 'PartialConfig' into 'ResolvedOpts'.
-- Every field must be 'Just' (either set explicitly or filled by 'defaultConfig').
-- Reports all missing fields at once rather than stopping at the first.
resolveOpts :: PartialConfig -> Either String ResolvedOpts
resolveOpts pc =
  case missing of
    [] ->
      Right
        ResolvedOpts
          { resolvedAddr = grab (pcAddr pc)
          , resolvedPort = grab (pcPort pc)
          , resolvedNodeConfig = grab (pcNodeConfig pc)
          , resolvedRtsFrequency = RTSFrequency $ grab (pcRtsFrequency pc)
          , resolvedCacheDir = grab (pcCacheDir pc)
          , resolvedSrcUrl = dropWhileEnd (== '/') $ grab (pcSrcUrl pc)
          , resolvedMaxCachedChunks = MaxCachedChunksCount $ grab (pcMaxCachedChunks pc)
          , resolvedPrefetchAhead = PrefetchChunksCount $ grab (pcPrefetchAhead pc)
          , resolvedTipRefreshInterval = TipRefreshInterval $ grab (pcTipRefreshInterval pc)
          , resolvedMaxRetries = grab (pcMaxRetries pc)
          , resolvedBaseDelay = asRetryBaseDelay $ grab (pcBaseDelay pc)
          }
    _ ->
      Left $
        "Missing required option(s): "
          ++ intercalate ", " (sort missing)
          ++ " (set via CLI or config file)"
 where
  grab = fromMaybe (error "unreachable: field checked but missing")
  missing =
    [name | (name, True) <- checks]
  checks =
    [ ("addr", isNothing (pcAddr pc))
    , ("port", isNothing (pcPort pc))
    , ("node-config", isNothing (pcNodeConfig pc))
    , ("rts-frequency", isNothing (pcRtsFrequency pc))
    , ("cache-dir", isNothing (pcCacheDir pc))
    , ("rs-src-url", isNothing (pcSrcUrl pc))
    , ("max-cached-chunks", isNothing (pcMaxCachedChunks pc))
    , ("prefetch-ahead", isNothing (pcPrefetchAhead pc))
    , ("tip-refresh-interval", isNothing (pcTipRefreshInterval pc))
    , ("max-retries", isNothing (pcMaxRetries pc))
    , ("base-delay", isNothing (pcBaseDelay pc))
    ]

showAddr :: HostAddr -> String
showAddr (a, b, c, d) = intercalate "." $ map show [a, b, c, d]
