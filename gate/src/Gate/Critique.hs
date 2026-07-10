-- | Phase 1: adversarial critique.
--
-- A fresh independent critic (default Opus, full tools and MCP) tries to PROVE
-- THE WORKER WRONG about both the code it changed and the claims it made this
-- turn, by running tests and commands and searching authoritative sources. It
-- also flags any factual claim it can find no supporting source for, since an
-- assertion the worker cannot back is itself evidence. The prompt is anchored to
-- ground truth (the round number and the repo's real commit history) so the
-- critic judges the current state and maps CI runs to commits by sha rather than
-- reconstructing the order from run timestamps. A substantiated
-- CHALLENGE blocks the turn. The critic is an advisor, not a wall:
-- exactly like dumbify, convergence is observed via the edit stack, so a turn
-- with no new edits (the worker stood by its work) is a shrug that ends the
-- debate. Runs after dumbify (so it verifies the canary's refactor too) and
-- before rule review (so its fixes land on the stack and get rule-checked).
module Gate.Critique
  ( runCritique
  , critiqueDiffBlock
  , recentClaims
  , critiqueAnchor
  ) where

import Control.Monad (when)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Gate.DiffRender (renderDiffs)
import Gate.EditStack (readEdits, stackFilePaths)
import Gate.GateConfig (envInt, envStr, phaseDisabled)
import Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Gate.NestedClaude (NestedResult (NestedBroken, NestedOutput), Reviewer (Reviewer), runNested, surfaceNestedFailure)
import Gate.Repo (commitHistory, repoForFilesOrCwd)
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

-- | Keep the most recent claims within the character budget. The worker's prose
-- accumulates across a turn's critique rounds (a block is not a turn boundary,
-- so 'turnAssistantText' keeps growing), and it is chronological. Trimming from
-- the FRONT would hand the critic the OLDEST claims (round 1, the first CI runs)
-- and drop the newest (the current HEAD's claims), so the critic judges stale
-- claims and misattributes runs. Trim from the end so the current round survives.
recentClaims :: Int -> Text -> Text
recentClaims = Text.takeEnd

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
  claims <- maybe (pure "") (fmap (recentClaims maxCritiqueClaimChars) . turnAssistantText) transcript
  files <- stackFilePaths (reviewStack paths)
  diffs <- critiqueDiffBlock hasEdits (reviewStack paths)
  repo <- repoForFilesOrCwd files
  history <- maybe (pure Nothing) commitHistory repo
  previous <- readPreviousChallenges (critiquePrev paths)
  previousRound <- readCounter (critiqueRound paths)
  maxRounds <- envInt "CLAUDE_CRITIQUE_MAX_ROUNDS" 2
  timeoutSecs <- envInt "CLAUDE_CRITIQUE_TIMEOUT" 1200
  model <- envStr "CLAUDE_CRITIQUE_MODEL" "claude-opus-4-8"
  -- The round is computed once and threaded to both the prompt and the block, so
  -- the critic is told the same round the worker is (the nested critic runs with
  -- the critique phase disabled, so it never bumps this counter mid-round).
  let thisRound = previousRound + 1
      reviewer = Reviewer model False timeoutSecs repo
      prompt = critiquePrompt (critiqueAnchor thisRound maxRounds history) previous claims diffs
  result <- runNested reviewer prompt
  case result of
    NestedBroken exitCode emptyOut stderrText -> do
      surfaceNestedFailure session "critique" model exitCode emptyOut stderrText (critiqueBroke paths)
      writeFlag (critiqueDone paths)
    NestedOutput output ->
      if hasChallenge output
        then handleChallenge paths model output currentMark thisRound maxRounds
        else do
          -- Clean OK: critique is done and this turn cleared.
          writeFlag (critiqueDone paths)
          writeFlag (critiqueApproved paths)

handleChallenge :: TurnPaths -> Text -> Text -> Int -> Int -> Int -> IO ()
handleChallenge paths model output currentMark thisRound maxRounds = do
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

-- | The diff block shown to the critic. Only a turn that recorded edits has a
-- review stack on disk; a conversational turn has none, and reading the absent
-- stack would crash this phase before the critic runs (the critic is meant to
-- run on every turn, edits or not). So read the stack only when there are edits,
-- and otherwise hand the critic the explicit no-edits placeholder.
critiqueDiffBlock :: Bool -> FilePath -> IO Text
critiqueDiffBlock hasEdits stackPath =
  if hasEdits
    then renderDiffs <$> readEdits stackPath
    else pure "(no file edits this turn)"

readPreviousChallenges :: FilePath -> IO (Maybe Text)
readPreviousChallenges path = do
  present <- doesFileExist path
  if present then Just <$> TextIO.readFile path else pure Nothing

hasChallenge :: Text -> Bool
hasChallenge output = any ("CHALLENGE:" `Text.isPrefixOf`) (Text.lines output)

critiquePrompt :: Text -> Maybe Text -> Text -> Text -> Text
critiquePrompt anchor previous claims diffs =
  Text.concat
    [ critiqueHeader
    , "\n=== GROUND TRUTH (authoritative; use this, do not reconstruct it from timestamps) ===\n"
    , anchor
    , maybe "" ("\n=== YOUR PREVIOUS CHALLENGES (the worker has since responded and may have changed code or claims; only re-raise what still holds and you can still substantiate) ===\n" <>) previous
    , "\n=== WHAT THE WORKER CLAIMS THIS TURN ===\n"
    , if Text.null claims then "(no transcript claims available)\n" else claims <> "\n"
    , "\n=== CODE CHANGES THIS TURN (may be empty) ===\n"
    , Text.take maxDiffPromptChars diffs
    ]

-- | The ground-truth anchor: which round this critique is, and the repo's real
-- commit history. A critic with full tools cross-checks external CI runs; stating
-- the round stops it renumbering the debate from the worker's prose, and the
-- commit history (HEAD first, with each commit's timestamp) lets it map a run to
-- a commit by sha instead of inferring the order from run start times. A missing
-- history is rendered as an explicit placeholder, never dropped silently.
critiqueAnchor :: Int -> Int -> Maybe Text -> Text
critiqueAnchor thisRound maxRounds history =
  Text.concat
    [ "This is critique round ", Text.pack (show thisRound), " of at most "
    , Text.pack (show maxRounds), " this turn. The worker's prose this turn may recount"
    , " earlier rounds; judge the CURRENT state and keep this round numbering, do not"
    , " renumber the debate.\n"
    , "Repo commit history, newest first, one commit per line as"
    , " \"<full-sha> <committer-ISO-8601-date> <subject>\"; the FIRST line is HEAD."
    , " Map any CI run to a commit by its sha (a run can start on an older HEAD and"
    , " finish after a newer commit exists, so run start time is not commit order):\n"
    , fromMaybe "(git commit history unavailable)" history
    , "\n"
    ]

critiqueHeader :: Text
critiqueHeader =
  "You are an adversarial correctness critic. A different, larger Claude Code agent\n\
  \just finished a turn. Below are the code changes it made (possibly none) and the\n\
  \claims it made about what it did or found. Your single job is to PROVE THE WORKER\n\
  \WRONG, by any means necessary. Assume both the code and the claims are wrong until\n\
  \you have evidence otherwise. A factual claim you can neither reproduce nor find any\n\
  \authoritative source for does not earn the benefit of the doubt: an assertion the\n\
  \worker cannot back is a weakness to surface, not something to wave through.\n\
  \\n\
  \Use every tool you have to gather counter-evidence:\n\
  \\n\
  \- For code: write and run tests, run the type-checker/build, run a one-off\n\
  \  command. Look for logic errors that still typecheck (wrong boundaries, inverted\n\
  \  conditions, unhandled cases, off-by-one, broken invariants, missing coverage)\n\
  \  and ways the change breaks the rest of the codebase.\n\
  \- For prose/claims: check them against reality. Run the command the worker says\n\
  \  it ran. Search the web and read authoritative sources, both to contradict a\n\
  \  factual claim and to look for the support the worker never cited. A claim of\n\
  \  \"I verified X\" that was never actually demonstrated is itself suspect. When\n\
  \  the worker states a checkable fact as established (attributing a view to\n\
  \  someone, quoting a spec, describing what a tool or library does), actively try\n\
  \  to find the authoritative source that backs it.\n\
  \\n\
  \Rank your counter-evidence by authority, and gather as much as you can:\n\
  \\n\
  \- Strongest: a failing test, a non-zero exit code, a command you ran and its\n\
  \  output. A machine cannot misreport these.\n\
  \- Good: an authoritative external source (documentation, a standard, a primary\n\
  \  source) that contradicts the claim. Cite the URL and quote the line.\n\
  \- Also evidence: the ABSENCE of a source. If the worker asserts a checkable fact\n\
  \  as established and you genuinely search for it (authoritative docs, the primary\n\
  \  source, the web) and find nothing that supports it, report that. Your evidence\n\
  \  is the search itself: name the queries you ran and the sources you checked, show\n\
  \  they turned up nothing backing the claim, and ask why the worker is asserting it.\n\
  \  Absence only counts once you have actually looked, so \"I did not look\" is not\n\
  \  \"no source exists\". This is for facts presented as established, not for the\n\
  \  worker's own clearly-labelled opinions, recommendations, or plans.\n\
  \- More independent counter-evidence is stronger than one: a test AND a source\n\
  \  beats either alone.\n\
  \- Not evidence: your own opinion or doubt with no search behind it. If you have\n\
  \  neither a test, a command, a cited source, nor a documented failed search, DROP\n\
  \  it.\n\
  \\n\
  \Do not add files to the repository under review; use /tmp for scratch\n\
  \reproducers. Do not flag style, naming, or \"could be cleaner\".\n\
  \\n\
  \Response format, no markdown:\n\
  \\n\
  \- If you cannot prove anything wrong: respond with the single line OK.\n\
  \- Otherwise, one block per item you are challenging:\n\
  \\n\
  \    CHALLENGE: <one-sentence summary of what is wrong or unsupported>\n\
  \    CLAIM: <the worker claim or code behaviour you are challenging>\n\
  \    EVIDENCE: <for a refutation: the test/command you ran and its output, and/or a\n\
  \              source URL with the contradicting quote. For an unsourced claim: the\n\
  \              searches you ran, e.g. \"I searched X and Y and found nothing that\n\
  \              supports Z\", listing the queries and sources checked. Concrete and\n\
  \              reproducible either way.>\n\
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
    , "  1. Agree: fix the code, correct the claim, or (for an unsourced factual claim) cite a source or retract it. Code fixes are re-critiqued and rule-checked automatically.\n"
    , "  2. Disagree: rebut it with STRONGER evidence than the critic brought (run the test yourself, cite a better source), or simply stand by your work. Do not just assert.\n"
    , "Engage every challenge, then decide. If you make no further edits, the gate takes that as your considered judgement and moves on (a shrug is allowed); it does not re-litigate. Set CLAUDE_SKIP_CRITIQUE=1 to disable this gate.\n"
    , "\n--- critic challenges ---\n"
    , output
    , "\n--- end critic challenges ---"
    ]
