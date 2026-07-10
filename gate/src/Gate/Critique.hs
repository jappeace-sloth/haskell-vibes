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
--
-- The claims are read from the transcript by POLLING ('readTurnClaims'):
-- Claude Code can fire the Stop hook before the turn's final assistant message
-- is flushed to the transcript file, and a single immediate read loses that
-- race. A turn that still offers neither claims nor edits after polling is an
-- EMPTY DOSSIER and fails loudly ('classifyDossier'): a critic spawned with
-- nothing to refute can only answer OK, and recording that OK as approval
-- would be a false green stamp.
module Gate.Critique
  ( runCritique
  , critiqueDiffBlock
  , recentClaims
  , critiqueAnchor
  , retryWhileEmpty
  , classifyDossier
  , CritiqueDossier(..)
  , EditPresence(..)
  , RoundBudget(..)
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Gate.DiffRender (renderDiffs)
import Gate.EditStack (readEdits, stackFilePaths)
import Gate.GateConfig (envInt, envStr, phaseDisabled)
import Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Gate.NestedClaude
  ( GateFailure (GateFailure, failureBlockReason, failureHeadline, failureLogBody, failureUserNotice)
  , NestedResult (NestedBroken, NestedOutput)
  , Reviewer (Reviewer)
  , runNested
  , surfaceGateFailure
  , surfaceNestedFailure
  )
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

-- | Which critique round this is, and the cap it counts against. The two travel
-- together through the anchor, the block reason, and 'handleChallenge'; bundling
-- them keeps the round and its cap from being swapped at a call site (both are
-- 'Int'), and threading one value keeps the number the critic is told identical
-- to the number the worker is told.
data RoundBudget = RoundBudget
  { thisRound :: Int
  , maxRounds :: Int
  }

-- | Whether this turn recorded file edits onto the review stack. The fact
-- travels through the whole phase (mark computation, dossier classification,
-- diff rendering), so it gets named constructors rather than a bare Bool.
data EditPresence = EditsRecorded | NoEditsRecorded
  deriving stock (Eq, Show)

editPresence :: TurnPaths -> IO EditPresence
editPresence paths = do
  stackNonEmpty <- fileNonEmpty (reviewStack paths)
  pure (if stackNonEmpty then EditsRecorded else NoEditsRecorded)

runCritique :: Text -> Maybe FilePath -> TurnPaths -> IO ()
runCritique session transcript paths = do
  disabled <- phaseDisabled "CLAUDE_SKIP_CRITIQUE"
  done <- flagExists (critiqueDone paths)
  claudeAvailable <- isJust <$> findExecutable "claude"
  when (not disabled && not done && claudeAvailable) $ do
    edits <- editPresence paths
    currentMark <- case edits of
      EditsRecorded -> stackLineCount (reviewStack paths)
      NoEditsRecorded -> pure 0
    previousMark <- readMark (critiqueEditmark paths)
    if previousMark == Just currentMark
      then
        -- The critic already challenged this turn and the worker made no new
        -- edits since: it stood by its work. A shrug ends the debate.
        writeFlag (critiqueDone paths)
      else runCritiqueRound session transcript paths edits currentMark

runCritiqueRound :: Text -> Maybe FilePath -> TurnPaths -> EditPresence -> Int -> IO ()
runCritiqueRound session transcript paths edits currentMark = do
  claims <- recentClaims maxCritiqueClaimChars <$> readTurnClaims transcript
  case classifyDossier claims edits of
    EmptyDossier -> surfaceEmptyDossier session transcript paths
    DossierReady -> runCriticOnDossier session paths edits currentMark claims

-- Decision: poll the transcript for the turn's claims instead of reading it
-- once. Claude Code fires the Stop hook before it has flushed the turn's final
-- assistant message to the transcript file (observed lag ~0.7s), so a single
-- immediate read handed the critic an empty dossier it could only wave OK at.
-- Alternatives considered: one fixed sleep before reading (pays the full delay
-- on every turn, even when the flush already happened) and filesystem watching
-- (a new dependency for a bounded, sub-second race). Polling costs nothing on
-- the common path because the first non-blank read returns immediately.
claimsFlushAttempts :: Int
claimsFlushAttempts = 5

-- | The pause between transcript polls. The observed flush lag is well under a
-- second, so the second attempt normally wins the race.
claimsFlushDelayMicroseconds :: Int
claimsFlushDelayMicroseconds = 1_000_000

-- | The worker's prose for this turn, polled per the Decision above. A Stop
-- event without a transcript path yields empty claims immediately; whether an
-- empty result is fatal is decided by 'classifyDossier', not here.
readTurnClaims :: Maybe FilePath -> IO Text
readTurnClaims Nothing = pure ""
readTurnClaims (Just path) =
  retryWhileEmpty claimsFlushAttempts claimsFlushDelayMicroseconds (turnAssistantText path)

-- | Run the read until it yields non-blank text, up to the attempt budget,
-- sleeping the given microseconds between attempts. The final attempt's result
-- is returned as-is (possibly still blank); the caller decides what that means.
retryWhileEmpty :: Int -> Int -> IO Text -> IO Text
retryWhileEmpty attempts delayMicroseconds readAction = do
  result <- readAction
  if not (Text.null (Text.strip result)) || attempts <= 1
    then pure result
    else do
      threadDelay delayMicroseconds
      retryWhileEmpty (attempts - 1) delayMicroseconds readAction

-- | Whether the turn gives the critic anything to refute. Claims that are all
-- whitespace count as absent, exactly like a missing transcript.
data CritiqueDossier = EmptyDossier | DossierReady
  deriving stock (Eq, Show)

classifyDossier :: Text -> EditPresence -> CritiqueDossier
classifyDossier claims edits = case edits of
  EditsRecorded -> DossierReady
  NoEditsRecorded ->
    if Text.null (Text.strip claims)
      then EmptyDossier
      else DossierReady

-- | Fail loudly on an empty dossier, mirroring 'surfaceNestedFailure': log it
-- durably and block the Stop once per turn with a user-visible notice. On a
-- repeat occurrence within the turn the phase gives up WITHOUT writing the
-- approved flag, so the missing critique is never recorded as a clean pass.
surfaceEmptyDossier :: Text -> Maybe FilePath -> TurnPaths -> IO ()
surfaceEmptyDossier session transcript paths = do
  surfaceGateFailure session (emptyDossierFailure transcript) (critiqueBroke paths)
  writeFlag (critiqueDone paths)

-- | The empty dossier described for 'surfaceGateFailure'. The log records the
-- transcript path the hook event carried (or its absence), which is the first
-- thing to check when debugging why the claims came up empty.
emptyDossierFailure :: Maybe FilePath -> GateFailure
emptyDossierFailure transcript =
  GateFailure
    { failureHeadline = "critique got an empty dossier (no claims, no edits)"
    , failureLogBody = "transcript_path=" <> maybe "(absent from Stop event)" Text.pack transcript
    , failureBlockReason = emptyDossierReason
    , failureUserNotice = emptyDossierNotice
    }

emptyDossierReason :: Text
emptyDossierReason =
  "GATE INPUT FAILURE in the critique phase: even after polling the transcript, \
  \this turn shows no assistant text and has no recorded edits, so there was \
  \nothing to hand the critic and this turn was NOT critiqued. An empty dossier \
  \is never a clean pass. Likely causes: the Stop event carried no \
  \transcript_path, or the transcript flush lagged past the polling window. \
  \This warning fires once per turn; you may continue after acknowledging it."

emptyDossierNotice :: Text
emptyDossierNotice =
  "vibes-gate: the critique phase found no claims in the transcript and no \
  \edits even after polling, so this turn was NOT critiqued. Details in the \
  \gate failure log ($CLAUDE_GATE_FAILURE_LOG, default ~/.claude/gate-failures.log)."

-- | Spawn the nested critic on a non-empty dossier and act on its verdict.
runCriticOnDossier :: Text -> TurnPaths -> EditPresence -> Int -> Text -> IO ()
runCriticOnDossier session paths edits currentMark claims = do
  files <- stackFilePaths (reviewStack paths)
  diffs <- critiqueDiffBlock edits (reviewStack paths)
  repo <- repoForFilesOrCwd files
  history <- maybe (pure Nothing) commitHistory repo
  previous <- readPreviousChallenges (critiquePrev paths)
  previousRound <- readCounter (critiqueRound paths)
  roundCap <- envInt "CLAUDE_CRITIQUE_MAX_ROUNDS" 2
  timeoutSecs <- envInt "CLAUDE_CRITIQUE_TIMEOUT" 1200
  model <- envStr "CLAUDE_CRITIQUE_MODEL" "claude-opus-4-8"
  -- The round is computed once and threaded to both the prompt and the block, so
  -- the critic is told the same round the worker is (the nested critic runs with
  -- the critique phase disabled, so it never bumps this counter mid-round).
  let budget = RoundBudget { thisRound = previousRound + 1, maxRounds = roundCap }
      reviewer = Reviewer model False timeoutSecs repo
      prompt = critiquePrompt (critiqueAnchor budget history) previous claims diffs
  result <- runNested reviewer prompt
  case result of
    NestedBroken exitCode emptyOut stderrText -> do
      surfaceNestedFailure session "critique" model exitCode emptyOut stderrText (critiqueBroke paths)
      writeFlag (critiqueDone paths)
    NestedOutput output ->
      if hasChallenge output
        then handleChallenge paths model output currentMark budget
        else do
          -- Clean OK: critique is done and this turn cleared.
          writeFlag (critiqueDone paths)
          writeFlag (critiqueApproved paths)

handleChallenge :: TurnPaths -> Text -> Text -> Int -> RoundBudget -> IO ()
handleChallenge paths model output currentMark budget = do
  writeCounter (critiqueRound paths) (thisRound budget)
  if thisRound budget <= maxRounds budget
    then do
      -- Record this challenge and the stack size it was based on. No new edits
      -- before the next Stop reads as a shrug; new edits earn a fresh critique.
      TextIO.writeFile (critiquePrev paths) output
      writeCounter (critiqueEditmark paths) currentMark
      blockAndExit (BlockReason (critiqueBlockReason model budget output))
    else
      -- Round cap reached: stop debating without marking approved (the concern
      -- is unresolved), and let rule review proceed.
      writeFlag (critiqueDone paths)

-- | The diff block shown to the critic. Only a turn that recorded edits has a
-- review stack on disk; a conversational turn has none, and reading the absent
-- stack would crash this phase before the critic runs (the critic is meant to
-- run on every turn, edits or not). So read the stack only when there are edits,
-- and otherwise hand the critic the explicit no-edits placeholder.
critiqueDiffBlock :: EditPresence -> FilePath -> IO Text
critiqueDiffBlock edits stackPath = case edits of
  EditsRecorded -> renderDiffs <$> readEdits stackPath
  NoEditsRecorded -> pure "(no file edits this turn)"

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
critiqueAnchor :: RoundBudget -> Maybe Text -> Text
critiqueAnchor RoundBudget { thisRound, maxRounds } history =
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

critiqueBlockReason :: Text -> RoundBudget -> Text -> Text
critiqueBlockReason model RoundBudget { thisRound, maxRounds } output =
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
