-- | The Stop hook: the end-of-turn gate.
--
-- Two phases run in order over the per-turn state.
--
--   Phase A (rule review). Claim the review stack record-edit built this turn
--   and review every diff in a single reviewer call against the rules corpus.
--   If the reviewer reports violations the Stop is blocked with the findings, so
--   the main-loop model can fix or rebut. Fixes are themselves edits, recorded
--   on a fresh stack and re-reviewed next Stop, so review loops until clean.
--
--   Phase B (verification). Only once review is clean, and only if the turn
--   actually touched state, the gate asks the model to verify its work through
--   external observation. A one-shot flag makes it fire at most once per turn.
module Gate.StopGate
  ( runStopGate
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.List (nub, sort)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Gate.Corpus (buildCorpus)
import Gate.DiffRender (renderDiffs)
import Gate.Edit (Edit, editFilePath)
import Gate.HookProtocol
  ( BlockReason (BlockReason)
  , HookEvent (sessionId, transcriptPath)
  , emitBlock
  , readHookEvent
  )
import Gate.ReviewPrompt
  ( buildReviewPrompt
  , hasViolations
  , reviewBlockReason
  , reviewerModel
  , verifyReason
  )
import Gate.Transcript (turnTouchedState)
import Gate.TurnState
  ( TurnPaths (claimedStack, reviewStack, verifyDoneFlag)
  , claimReviewStack
  , ensureStateDir
  , turnPaths
  )
import System.Directory (doesFileExist, findExecutable, getFileSize, removeFile)
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)

-- | Entry point for the @stop-gate@ subcommand.
runStopGate :: IO ()
runStopGate = do
  event <- readHookEvent
  paths <- turnPaths (sessionId event)
  ensureStateDir paths
  blockedByReview <- runRuleReview paths
  -- Phase B only runs when Phase A did not already block the Stop.
  unless blockedByReview (runVerification event paths)

-- =====================  Phase A: rule review  ==============================

-- | Review this turn's recorded edits. Returns whether it emitted a block.
runRuleReview :: TurnPaths -> IO Bool
runRuleReview paths = do
  disabled <- ruleCheckDisabled
  claudeAvailable <- isJust <$> findExecutable "claude"
  stackReady <- fileNonEmpty (reviewStack paths)
  if disabled || not claudeAvailable || not stackReady
    then pure False
    else reviewClaimedStack paths

reviewClaimedStack :: TurnPaths -> IO Bool
reviewClaimedStack paths = do
  -- Claim atomically so edits made after this point are reviewed next Stop.
  claimed <- claimReviewStack paths
  claimedReady <- if claimed then fileNonEmpty (claimedStack paths) else pure False
  if not claimedReady
    then pure False
    else do
      edits <- readEdits (claimedStack paths)
      corpus <- buildCorpus (sortUniqueFilePaths edits)
      reviewOutput <- runReviewer (buildReviewPrompt corpus (renderDiffs edits))
      removeIfExists (claimedStack paths)
      if hasViolations reviewOutput
        then do
          -- New fixes are coming, so re-arm verification to run after them.
          removeIfExists (verifyDoneFlag paths)
          emitBlock (BlockReason (reviewBlockReason reviewOutput))
          pure True
        else pure False

sortUniqueFilePaths :: [Edit] -> [FilePath]
sortUniqueFilePaths = sort . nub . map editFilePath

-- | Read the claimed stack back into edits. We wrote these lines ourselves, so a
-- line that fails to decode is a bug in this program, surfaced loudly.
readEdits :: FilePath -> IO [Edit]
readEdits path = do
  contents <- ByteString.readFile path
  pure (map decodeEdit (filter (not . ByteString.null) (ByteString.lines contents)))

decodeEdit :: ByteString.ByteString -> Edit
decodeEdit raw = case Aeson.eitherDecodeStrict raw of
  Right edit -> edit
  Left err -> error ("vibes-gate stop-gate: corrupt edit on review stack: " <> err)

-- | Run the reviewer model on the prompt, returning its stdout. Decision: treat
-- any failure (timeout, CLI error, network hiccup) as empty output, which
-- 'hasViolations' reads as clean. Blocking a turn because the reviewer
-- subprocess failed would be worse than skipping one review. The 60s timeout
-- guards against a hung subprocess holding the turn open.
runReviewer :: Text -> IO Text
runReviewer prompt = do
  result <-
    try
      ( readProcessWithExitCode
          "timeout"
          ["60", "claude", "-p", "--model", Text.unpack reviewerModel]
          (Text.unpack prompt)
      )
  pure $ case result of
    Right (_exit, out, _err) -> Text.pack out
    Left (_ioError :: IOException) -> ""

-- =====================  Phase B: verification  =============================

-- | Ask the model to verify its work, once per turn, if the turn touched state.
runVerification :: HookEvent -> TurnPaths -> IO ()
runVerification event paths = do
  disabled <- verifyCheckDisabled
  alreadyAsked <- doesFileExist (verifyDoneFlag paths)
  if disabled || alreadyAsked
    then pure ()
    else case transcriptPath event of
      Nothing -> pure ()
      Just path -> do
        touched <- turnTouchedState path
        when touched $ do
          -- Arm the one-shot, then ask. Review has already passed by here.
          writeFile (verifyDoneFlag paths) ""
          emitBlock (BlockReason verifyReason)

-- =====================  shared helpers  ====================================

ruleCheckDisabled :: IO Bool
ruleCheckDisabled = (== Just "1") <$> lookupEnv "CLAUDE_SKIP_RULE_CHECK"

verifyCheckDisabled :: IO Bool
verifyCheckDisabled = (== Just "1") <$> lookupEnv "CLAUDE_SKIP_VERIFY_CHECK"

fileNonEmpty :: FilePath -> IO Bool
fileNonEmpty path = do
  present <- doesFileExist path
  if present then (> 0) <$> getFileSize path else pure False

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  present <- doesFileExist path
  when present (removeFile path)
