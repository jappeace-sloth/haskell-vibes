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

import Control.Exception.Safe (SomeException, displayException, tryAny)
import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub, sort)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
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
  , reviewerFailedReason
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
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)

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
      result <- runReviewer (buildReviewPrompt corpus (renderDiffs edits))
      removeIfExists (claimedStack paths)
      case result of
        ReviewedClean -> pure False
        ReviewedViolations reviewOutput -> do
          -- New fixes are coming, so re-arm verification to run after them.
          removeIfExists (verifyDoneFlag paths)
          emitBlock (BlockReason (reviewBlockReason reviewOutput))
          pure True
        ReviewerFailed detail -> do
          -- Do not treat a failed reviewer as clean: surface it loudly so the
          -- turn is not silently trusted on an unchecked diff.
          removeIfExists (verifyDoneFlag paths)
          emitBlock (BlockReason (reviewerFailedReason detail))
          pure True

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

-- | The outcome of the Phase A reviewer call. Distinguishing a real verdict
-- from an infrastructure failure is the whole point: a failed reviewer must be
-- surfaced, not silently read as "no violations".
data ReviewResult
  = ReviewedClean
  | ReviewedViolations Text
  | ReviewerFailed Text

-- | Run the reviewer model on the prompt over typed-process. Decision: a clean
-- run with no @VIOLATION:@ lines is ReviewedClean; violations are
-- ReviewedViolations; a non-zero exit (the 60s @timeout@ wrapper fires 124 on a
-- hang) or a spawn exception is ReviewerFailed, carrying the detail. Nothing is
-- swallowed: the caller surfaces a failure rather than treating it as clean.
runReviewer :: Text -> IO ReviewResult
runReviewer prompt = do
  let reviewerProcess =
        setStdin
          (byteStringInput (LazyByteString.fromStrict (encodeUtf8 prompt)))
          (proc "timeout" ["60", "claude", "-p", "--model", Text.unpack reviewerModel])
  outcome <- tryAny (readProcess reviewerProcess)
  pure (interpretReviewer outcome)

interpretReviewer
  :: Either SomeException (ExitCode, LazyByteString.ByteString, LazyByteString.ByteString)
  -> ReviewResult
interpretReviewer = \case
  Left err -> ReviewerFailed (Text.pack (displayException err))
  Right (ExitSuccess, out, _err) -> classifyReviewOutput (decodeLazy out)
  Right (ExitFailure code, _out, err) ->
    ReviewerFailed ("the reviewer process exited with code " <> Text.pack (show code) <> reviewerStderr err)

classifyReviewOutput :: Text -> ReviewResult
classifyReviewOutput output
  | hasViolations output = ReviewedViolations output
  | otherwise = ReviewedClean

reviewerStderr :: LazyByteString.ByteString -> Text
reviewerStderr raw = case Text.strip (decodeLazy raw) of
  "" -> ""
  err -> ": " <> err

decodeLazy :: LazyByteString.ByteString -> Text
decodeLazy = decodeUtf8Lenient . LazyByteString.toStrict

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
