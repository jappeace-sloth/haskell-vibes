-- | Phase A: rule review.
--
-- Claims the edit stack and reviews every diff in a single reviewer call against
-- the rules corpus (global and project CLAUDE.md plus the skills matching the
-- touched file types), with the full file contents for context. Violations block
-- the Stop with the findings; the model's fixes are themselves edits, recorded on
-- a fresh stack and re-reviewed next Stop, so review loops until clean. A reviewer
-- that fails returns the diffs to the stack and is surfaced loudly.
module Gate.RuleReview
  ( runRuleReview
  ) where

import Control.Monad (when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Gate.Corpus (buildCorpus)
import Gate.DiffRender (renderDiffs)
import Gate.EditStack (readEdits, returnClaimedToStack, stackFilePaths)
import Gate.FileContext (renderFullFiles)
import Gate.GateConfig (envInt, phaseDisabled)
import Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Gate.NestedClaude (NestedResult (NestedBroken, NestedOutput), Reviewer (Reviewer), runNested, surfaceNestedFailure)
import Gate.ReviewPrompt (buildReviewPrompt, hasViolations, reviewBlockReason, reviewerModel)
import Gate.TurnState
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
  timeoutSecs <- envInt "CLAUDE_RULE_REVIEW_TIMEOUT" 150
  let reviewer = Reviewer reviewerModel True timeoutSecs Nothing
      prompt = buildReviewPrompt corpus (renderDiffs edits) fullFiles
  result <- runNested reviewer prompt
  case result of
    NestedBroken exitCode emptyOut stderrText -> do
      -- Do not lose the diffs: return them to the stack so the next Stop
      -- re-reviews once the reviewer works again, then surface the failure.
      returnClaimedToStack paths
      surfaceNestedFailure session "rule review" reviewerModel exitCode emptyOut stderrText (reviewBroke paths)
    NestedOutput output -> do
      removeIfExists (claimedStack paths)
      if hasViolations output
        then blockAndExit (BlockReason (reviewBlockReason output))
        else writeFlag (reviewApproved paths)
