-- | Phase A: rule review.
--
-- Claims the edit stack and reviews every diff in a single reviewer call against
-- the rules corpus (global and project CLAUDE.md plus the skills matching the
-- touched file types), with the full file contents for context. Violations block
-- the Stop with the findings; the model's fixes are themselves edits, recorded on
-- a fresh stack and re-reviewed next Stop, so review loops until clean. A reviewer
-- that fails returns the diffs to the stack and is surfaced loudly.
module Claude.Gate.RuleReview
  ( runRuleReview
  ) where

import Control.Monad (when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Claude.Gate.Corpus (buildCorpus)
import Claude.Gate.DiffRender (renderDiffs)
import Claude.Gate.EditStack (readEdits, returnClaimedToStack, stackFilePaths)
import Claude.Gate.FileContext (renderFullFiles)
import Claude.Gate.GateConfig (envInt, envStr, phaseDisabled)
import Claude.Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Claude.Gate.NestedClaude (NestedResult (NestedBroken, NestedOutput), Reviewer (Reviewer), runNested, surfaceNestedFailure)
import Claude.Gate.ReviewPrompt (buildReviewPrompt, hasViolations, reviewBlockReason)
import Claude.Gate.TurnState
  ( TurnPaths (claimedStack, reviewApproved, reviewBroke, reviewStack)
  , claimReviewStack
  , fileNonEmpty
  , removeIfExists
  , writeFlag
  )
import System.Directory (findExecutable)

runRuleReview :: Text -> TurnPaths -> IO ()
runRuleReview session paths = do
  disabled <- phaseDisabled "CLAUDE_SKIP_RULE_CHECK"
  claudeAvailable <- isJust <$> findExecutable "claude"
  stackReady <- fileNonEmpty (reviewStack paths)
  when (not disabled && claudeAvailable && stackReady) $ do
    -- Claim the stack atomically so any edit recorded after this point lands on a
    -- fresh stack and is reviewed on the next Stop rather than lost.
    claimed <- claimReviewStack paths
    claimedReady <- if claimed then fileNonEmpty (claimedStack paths) else pure False
    when claimedReady (reviewClaimed session paths)

reviewClaimed :: Text -> TurnPaths -> IO ()
reviewClaimed session paths = do
  files <- stackFilePaths (claimedStack paths)
  edits <- readEdits (claimedStack paths)
  corpus <- buildCorpus files
  fullFiles <- renderFullFiles files
  timeoutSecs <- envInt "CLAUDE_RULE_REVIEW_TIMEOUT" 300
  -- Phase A reviewer model. Decision: Sonnet rather than Haiku. The review only
  -- fires on turns that edited files and batches that turn's diffs into one call,
  -- so cost is per-edit-turn, not per-Stop, and the extra reasoning catches
  -- semantic violations (silent failures, tests asserting static content) a
  -- smaller model misses. The main-loop model is still the final judge. Read via
  -- the env, defaulting to the current Sonnet, so bumping the model to the next
  -- generation needs no rebuild, matching CLAUDE_CRITIQUE_MODEL / CLAUDE_DUMBIFY_MODEL.
  model <- envStr "CLAUDE_REVIEWER_MODEL" "claude-sonnet-5"
  let reviewer = Reviewer model True timeoutSecs Nothing
      prompt = buildReviewPrompt corpus (renderDiffs edits) fullFiles
  result <- runNested reviewer prompt
  case result of
    NestedBroken exitCode emptyOut stderrText -> do
      -- Do not lose the diffs: return them to the stack so the next Stop
      -- re-reviews once the reviewer works again, then surface the failure.
      returnClaimedToStack paths
      surfaceNestedFailure session "rule review" model exitCode emptyOut stderrText (reviewBroke paths)
    NestedOutput output -> do
      removeIfExists (claimedStack paths)
      if hasViolations output
        then blockAndExit (BlockReason (reviewBlockReason model output))
        else writeFlag (reviewApproved paths)
