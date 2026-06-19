-- | Per-turn state kept on tmpfs, shared by the three hooks.
--
-- A "turn" is one user prompt and everything the agent does to satisfy it.
-- record-edit appends to the review stack during the turn, the Stop gate claims
-- and reviews it, and reset wipes the whole directory when the next prompt
-- arrives. All of it lives under @$TMPDIR/claude-turn-state/<session>@ so it
-- clears on container restart.
module Gate.TurnState
  ( TurnPaths(..)
  , turnPaths
  , sanitiseSession
  , ensureStateDir
  , resetState
  , claimReviewStack
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, removePathForcibly, renameFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | The four state paths for one session. Grouping them keeps the layout in one
-- place rather than recomputed in each hook.
data TurnPaths = TurnPaths
  { stateDir :: FilePath
  , reviewStack :: FilePath
  , claimedStack :: FilePath
  , verifyDoneFlag :: FilePath
  }

-- | Resolve the state paths for a session id, reading TMPDIR the same way the
-- shell hooks did (defaulting to /tmp).
turnPaths :: Text -> IO TurnPaths
turnPaths session = do
  tmp <- fromMaybe "/tmp" <$> lookupEnv "TMPDIR"
  let dir = tmp </> "claude-turn-state" </> Text.unpack (sanitiseSession session)
  pure
    TurnPaths
      { stateDir = dir
      , reviewStack = dir </> "edits.jsonl"
      , claimedStack = dir </> "edits.processing"
      , verifyDoneFlag = dir </> "verify-done"
      }

-- | Make the session id safe to use as a single path component by replacing any
-- character outside @[A-Za-z0-9_.-]@ with an underscore, matching the shell
-- @tr -c@ the hooks used.
sanitiseSession :: Text -> Text
sanitiseSession = Text.map keepOrUnderscore

keepOrUnderscore :: Char -> Char
keepOrUnderscore character
  | isSafe character = character
  | otherwise = '_'

isSafe :: Char -> Bool
isSafe character =
  isAsciiUpper character
    || isAsciiLower character
    || isDigit character
    || character == '_'
    || character == '.'
    || character == '-'

ensureStateDir :: TurnPaths -> IO ()
ensureStateDir paths = createDirectoryIfMissing True (stateDir paths)

-- | Wipe a session's state directory. Used by the UserPromptSubmit reset so the
-- previous turn's review stack and verify-done flag do not leak into the next
-- turn.
resetState :: TurnPaths -> IO ()
resetState paths = removePathForcibly (stateDir paths)

-- | Atomically claim the review stack: rename edits.jsonl to edits.processing
-- so any edit recorded after this point lands on a fresh stack and is reviewed
-- on the next Stop rather than lost. Returns whether there was a stack to claim.
claimReviewStack :: TurnPaths -> IO Bool
claimReviewStack paths = do
  hasStack <- doesFileExist (reviewStack paths)
  if hasStack
    then renameFile (reviewStack paths) (claimedStack paths) >> pure True
    else pure False
