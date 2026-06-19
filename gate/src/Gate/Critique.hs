-- | Phase 1: adversarial critique.
--
-- A fresh independent critic (default Opus, full tools and MCP) tries to PROVE
-- THE WORKER WRONG about both the code it changed and the claims it made this
-- turn, by running tests and commands and searching authoritative sources. A
-- substantiated CHALLENGE blocks the turn. The critic is an advisor, not a wall:
-- exactly like dumbify, convergence is observed via the edit stack, so a turn
-- with no new edits (the worker stood by its work) is a shrug that ends the
-- debate. Runs after dumbify (so it verifies the canary's refactor too) and
-- before rule review (so its fixes land on the stack and get rule-checked).
module Gate.Critique
  ( runCritique
  ) where

import Control.Monad (when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Gate.DiffRender (renderDiffs)
import Gate.EditStack (readEdits, stackFilePaths)
import Gate.GateConfig (envInt, envStr, phaseDisabled)
import Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Gate.NestedClaude (NestedResult (NestedBroken, NestedOutput), Reviewer (Reviewer), runNested, surfaceNestedFailure)
import Gate.Repo (repoForFilesOrCwd)
import Gate.ReviewPrompt (maxDiffPromptChars)
import Gate.Transcript (turnAssistantText)
import Gate.TurnState
  ( TurnPaths (critiqueApproved, critiqueBroke, critiqueDone, critiqueEditmark, critiquePrev, critiqueRound, reviewStack)
  , fileNonEmpty
  , flagExists
  , readCounter
  , readMark
  , stackLineCount
  , writeCounter
  , writeFlag
  )
import System.Directory (doesFileExist, findExecutable)

-- | The critic refutes both the code and the claims, so it runs on EVERY turn,
-- including conversational ones with no edits. A shrug (no new edits since the
-- last challenge) ends the debate within the turn.
maxCritiqueClaimChars :: Int
maxCritiqueClaimChars = 16_000

runCritique :: Text -> Maybe FilePath -> TurnPaths -> IO ()
runCritique session transcript paths = do
  disabled <- phaseDisabled "CLAUDE_SKIP_CRITIQUE"
  done <- flagExists (critiqueDone paths)
  claudeAvailable <- isJust <$> findExecutable "claude"
  when (not disabled && not done && claudeAvailable) $ do
    hasEdits <- fileNonEmpty (reviewStack paths)
    currentMark <- if hasEdits then stackLineCount (reviewStack paths) else pure 0
    previousMark <- readMark (critiqueEditmark paths)
    if previousMark == Just currentMark
      then
        -- The critic already challenged this turn and the worker made no new
        -- edits since: it stood by its work. A shrug ends the debate.
        writeFlag (critiqueDone paths)
      else runCritiqueRound session transcript paths hasEdits currentMark

runCritiqueRound :: Text -> Maybe FilePath -> TurnPaths -> Bool -> Int -> IO ()
runCritiqueRound session transcript paths hasEdits currentMark = do
  claims <- maybe (pure "") (fmap (Text.take maxCritiqueClaimChars) . turnAssistantText) transcript
  files <- stackFilePaths (reviewStack paths)
  edits <- readEdits (reviewStack paths)
  repo <- repoForFilesOrCwd files
  previous <- readPreviousChallenges (critiquePrev paths)
  timeoutSecs <- envInt "CLAUDE_CRITIQUE_TIMEOUT" 1200
  model <- envStr "CLAUDE_CRITIQUE_MODEL" "claude-opus-4-8"
  let diffs = if hasEdits then renderDiffs edits else "(no file edits this turn)"
      reviewer = Reviewer model False timeoutSecs repo
      prompt = critiquePrompt previous claims diffs
  result <- runNested reviewer prompt
  case result of
    NestedBroken exitCode emptyOut stderrText -> do
      surfaceNestedFailure session "critique" model exitCode emptyOut stderrText (critiqueBroke paths)
      writeFlag (critiqueDone paths)
    NestedOutput output ->
      if hasChallenge output
        then handleChallenge paths currentMark model output
        else do
          -- Clean OK: critique is done and this turn cleared.
          writeFlag (critiqueDone paths)
          writeFlag (critiqueApproved paths)

handleChallenge :: TurnPaths -> Int -> Text -> Text -> IO ()
handleChallenge paths currentMark model output = do
  previousRound <- readCounter (critiqueRound paths)
  maxRounds <- envInt "CLAUDE_CRITIQUE_MAX_ROUNDS" 2
  let thisRound = previousRound + 1
  writeCounter (critiqueRound paths) thisRound
  if thisRound <= maxRounds
    then do
      -- Record this challenge and the stack size it was based on. No new edits
      -- before the next Stop reads as a shrug; new edits earn a fresh critique.
      TextIO.writeFile (critiquePrev paths) output
      writeCounter (critiqueEditmark paths) currentMark
      blockAndExit (BlockReason (critiqueBlockReason model thisRound maxRounds output))
    else
      -- Round cap reached: stop debating without marking approved (the concern
      -- is unresolved), and let rule review proceed.
      writeFlag (critiqueDone paths)

readPreviousChallenges :: FilePath -> IO (Maybe Text)
readPreviousChallenges path = do
  present <- doesFileExist path
  if present then Just <$> TextIO.readFile path else pure Nothing

hasChallenge :: Text -> Bool
hasChallenge output = any ("CHALLENGE:" `Text.isPrefixOf`) (Text.lines output)

critiquePrompt :: Maybe Text -> Text -> Text -> Text
critiquePrompt previous claims diffs =
  Text.concat
    [ critiqueHeader
    , maybe "" ("\n=== YOUR PREVIOUS CHALLENGES (the worker has since responded and may have changed code or claims; only re-raise what still holds and you can still substantiate) ===\n" <>) previous
    , "\n=== WHAT THE WORKER CLAIMS THIS TURN ===\n"
    , if Text.null claims then "(no transcript claims available)\n" else claims <> "\n"
    , "\n=== CODE CHANGES THIS TURN (may be empty) ===\n"
    , Text.take maxDiffPromptChars diffs
    ]

critiqueHeader :: Text
critiqueHeader =
  "You are an adversarial correctness critic. A different, larger Claude Code agent\n\
  \just finished a turn. Below are the code changes it made (possibly none) and the\n\
  \claims it made about what it did or found. Your single job is to PROVE THE WORKER\n\
  \WRONG, by any means necessary. Assume both the code and the claims are wrong until\n\
  \you have evidence otherwise.\n\
  \\n\
  \Use every tool you have to gather counter-evidence:\n\
  \\n\
  \- For code: write and run tests, run the type-checker/build, run a one-off\n\
  \  command. Look for logic errors that still typecheck (wrong boundaries, inverted\n\
  \  conditions, unhandled cases, off-by-one, broken invariants, missing coverage)\n\
  \  and ways the change breaks the rest of the codebase.\n\
  \- For prose/claims: check them against reality. Run the command the worker says\n\
  \  it ran. Search the web and read authoritative sources to contradict a factual\n\
  \  claim. A claim of \"I verified X\" that was never actually demonstrated is itself\n\
  \  suspect.\n\
  \\n\
  \Rank your counter-evidence by authority, and gather as much as you can:\n\
  \\n\
  \- Strongest: a failing test, a non-zero exit code, a command you ran and its\n\
  \  output. A machine cannot misreport these.\n\
  \- Good: an authoritative external source (documentation, a standard, a primary\n\
  \  source) that contradicts the claim. Cite the URL and quote the line.\n\
  \- More independent counter-evidence is stronger than one: a test AND a source\n\
  \  beats either alone.\n\
  \- Not evidence: your own opinion or doubt. If you cannot substantiate a challenge\n\
  \  with a test, a command, or a cited source, DROP it.\n\
  \\n\
  \Do not add files to the repository under review; use /tmp for scratch\n\
  \reproducers. Do not flag style, naming, or \"could be cleaner\".\n\
  \\n\
  \Response format, no markdown:\n\
  \\n\
  \- If you cannot prove anything wrong: respond with the single line OK.\n\
  \- Otherwise, one block per refuted item:\n\
  \\n\
  \    CHALLENGE: <one-sentence summary of what is wrong>\n\
  \    CLAIM: <the worker claim or code behaviour you are refuting>\n\
  \    EVIDENCE: <the test/command you ran and its output, and/or a source URL with\n\
  \              the contradicting quote. Concrete and reproducible.>\n\
  \    SEVERITY: blocker | major | minor\n\
  \\n\
  \Separate blocks with a blank line."

critiqueBlockReason :: Text -> Int -> Int -> Text -> Text
critiqueBlockReason model thisRound maxRounds output =
  Text.concat
    [ "A fresh adversarial ", model, " critic tried to prove your work wrong this turn, "
    , "using tests and sources, and produced the counter-evidence below (round "
    , Text.pack (show thisRound), " of ", Text.pack (show maxRounds)
    , "). This critic is an advisor, not a wall: you are the final judge. For each challenge, either:\n"
    , "  1. Agree: fix the code, or correct the claim. Code fixes are re-critiqued and rule-checked automatically.\n"
    , "  2. Disagree: rebut it with STRONGER evidence than the critic brought (run the test yourself, cite a better source), or simply stand by your work. Do not just assert.\n"
    , "Engage every challenge, then decide. If you make no further edits, the gate takes that as your considered judgement and moves on (a shrug is allowed); it does not re-litigate. Set CLAUDE_SKIP_CRITIQUE=1 to disable this gate.\n"
    , "\n--- critic challenges ---\n"
    , output
    , "\n--- end critic challenges ---"
    ]
