-- | Environment-tunable gate configuration: the skip flags and the integer
-- knobs (round caps, timeouts) each phase reads.
module Gate.GateConfig
  ( phaseDisabled
  , envInt
  , envStr
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | A @CLAUDE_SKIP_*@ flag is set when it equals exactly "1".
phaseDisabled :: String -> IO Bool
phaseDisabled name = (== Just "1") <$> lookupEnv name

-- | Read an integer environment knob, falling back to the default when it is
-- unset or not a number.
envInt :: String -> Int -> IO Int
envInt name fallback = do
  value <- lookupEnv name
  pure (fromMaybe fallback (value >>= readMaybe))

-- | Read a string environment knob (e.g. a model override), with a default.
envStr :: String -> Text -> IO Text
envStr name fallback = maybe fallback Text.pack <$> lookupEnv name
