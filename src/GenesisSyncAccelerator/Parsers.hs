module GenesisSyncAccelerator.Parsers (parseAddr) where

import Data.Bifunctor (first)
import GenesisSyncAccelerator.Types (HostAddr)
import Text.Read (readMaybe)

parseAddr :: String -> Either String HostAddr
parseAddr s = first contextualize $ traverse tryParse chunks >>= extractResult
 where
  contextualize msg = "Cannot parse address (" ++ s ++ "): " ++ msg
  chunks = reverse $ map reverse $ go s [] []
  go [] curr acc = curr : acc
  go ('.' : t) curr acc = go t [] (curr : acc)
  go (h : t) curr acc = go t (h : curr) acc
  tryParse sub = maybe (Left ("cannot parse component '" ++ sub ++ "'")) Right (readMaybe sub)
  extractResult [sub1, sub2, sub3, sub4] = Right (sub1, sub2, sub3, sub4)
  extractResult subs = Left (show (length subs) ++ " (not 4) components")
