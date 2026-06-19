-- | Phase 0: the dumbify complexity canary.
--
-- For code-touching turns, a small model (Haiku) reads the changed code with the
-- full files as context and explains it; the larger main-loop model judges that
-- explanation. If the canary could not work out what the code DOES, the code is
-- too complex and the larger model simplifies it (behaviour-preserving), which
-- re-triggers the canary. Convergence is OBSERVED via the edit stack: no new
-- edits since the last explanation means the larger model accepted it. Bounded
-- by CLAUDE_DUMBIFY_MAX_ROUNDS. Runs first so the cheap canary shapes the code
-- before the expensive critic verifies the result.
module Gate.Dumbify
  ( runDumbify
  ) where

import Control.Monad (when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Gate.DiffRender (renderDiffs)
import Gate.EditStack (readEdits, stackFilePaths, stackHasCode)
import Gate.FileContext (renderFullFiles)
import Gate.GateConfig (envInt, envStr, phaseDisabled)
import Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Gate.NestedClaude (NestedResult (NestedBroken, NestedOutput), Reviewer (Reviewer), runNested, surfaceNestedFailure)
import Gate.Repo (repoForFiles)
import Gate.ReviewPrompt (maxDiffPromptChars)
import Gate.TurnState
  ( TurnPaths (dumbifyApproved, dumbifyBroke, dumbifyDone, dumbifyEditmark, dumbifyRound, reviewStack)
  , fileNonEmpty
  , flagExists
  , readCounter
  , readMark
  , stackLineCount
  , writeCounter
  , writeFlag
  )
import System.Directory (findExecutable)

-- | Run Phase 0. Fires only for a code-touching turn whose stack has not yet
-- converged, and only when claude is available.
runDumbify :: Text -> TurnPaths -> IO ()
runDumbify session paths = do
  disabled <- phaseDisabled "CLAUDE_SKIP_DUMBIFY"
  done <- flagExists (dumbifyDone paths)
  stackReady <- fileNonEmpty (reviewStack paths)
  hasCode <- stackHasCode (reviewStack paths)
  claudeAvailable <- isJust <$> findExecutable "claude"
  when (not disabled && not done && stackReady && hasCode && claudeAvailable) $ do
    currentMark <- stackLineCount (reviewStack paths)
    previousMark <- readMark (dumbifyEditmark paths)
    if previousMark == Just currentMark
      then do
        -- No new edits since the last explanation: the larger model judged the
        -- explanation correct and chose not to simplify. Accept and move on.
        writeFlag (dumbifyDone paths)
        writeFlag (dumbifyApproved paths)
      else do
        previousRound <- readCounter (dumbifyRound paths)
        maxRounds <- envInt "CLAUDE_DUMBIFY_MAX_ROUNDS" 2
        let thisRound = previousRound + 1
        if thisRound > maxRounds
          then writeFlag (dumbifyDone paths)
          else runDumbifyRound session paths currentMark thisRound maxRounds

runDumbifyRound :: Text -> TurnPaths -> Int -> Int -> Int -> IO ()
runDumbifyRound session paths currentMark thisRound maxRounds = do
  files <- stackFilePaths (reviewStack paths)
  edits <- readEdits (reviewStack paths)
  fullFiles <- renderFullFiles files
  repo <- repoForFiles files
  timeoutSecs <- envInt "CLAUDE_DUMBIFY_TIMEOUT" 300
  model <- envStr "CLAUDE_DUMBIFY_MODEL" "claude-haiku-4-5"
  let reviewer = Reviewer model True timeoutSecs repo
      prompt = dumbifyPrompt (renderDiffs edits) fullFiles
  result <- runNested reviewer prompt
  case result of
    NestedBroken exitCode emptyOut stderrText -> do
      surfaceNestedFailure session "dumbify canary" model exitCode emptyOut stderrText (dumbifyBroke paths)
      writeFlag (dumbifyDone paths)
    NestedOutput output -> do
      -- Record the round and the stack size this explanation was based on, so the
      -- next Stop can tell whether the larger model simplified.
      writeCounter (dumbifyRound paths) thisRound
      writeCounter (dumbifyEditmark paths) currentMark
      blockAndExit (BlockReason (dumbifyBlockReason model thisRound maxRounds output))

dumbifyPrompt :: Text -> Text -> Text
dumbifyPrompt renderedDiffs fullFiles =
  Text.concat
    [ dumbifyHeader
    , "\n=== DIFFS JUST APPLIED THIS TURN ===\n"
    , Text.take maxDiffPromptChars renderedDiffs
    , "\n=== FULL CURRENT CONTENTS OF THE TOUCHED FILES (context: definitions the diffs reference live here) ===\n"
    , fullFiles
    ]

dumbifyHeader :: Text
dumbifyHeader =
  "You are a complexity canary. You are a small model reading code a larger agent\n\
  \just wrote, with no explanation from its author. Your job is to test whether the\n\
  \CHANGED code is understandable.\n\
  \\n\
  \You are given two things below: the diffs applied this turn, and the FULL current\n\
  \contents of each file they touched. Use the full file as context. A definition,\n\
  \variable, or helper that the diff references but that lives elsewhere in the file\n\
  \is available to you, so \"I can't see where X is defined\" is NOT a valid confusion\n\
  \unless X is genuinely absent from the file.\n\
  \\n\
  \For each function or section in the diffs, explain in your own words:\n\
  \- what it does,\n\
  \- what its inputs mean and what it returns,\n\
  \- and any concern that makes it hard to follow. Label each concern:\n\
  \    BLOCKS       - you could not work out what the changed code actually does.\n\
  \    NICE-TO-HAVE - you understood it, but a comment or clearer name would help.\n\
  \\n\
  \Rules:\n\
  \- Judge from the diffs plus the full files shown and anything else you can read in\n\
  \  the repository. Nobody will explain it to you; that is the point.\n\
  \- Be honest. If something genuinely stops you understanding the behaviour, say so\n\
  \  plainly and label it BLOCKS. Hedging (\"I think\", \"probably\", \"I'm not sure\")\n\
  \  about what the code DOES is itself a BLOCKS signal worth stating outright.\n\
  \- Do NOT report code outside this turn's change (untouched surrounding functions,\n\
  \  the harness/hook protocol that consumes this script's output, the build system)\n\
  \  as confusion. That is context, not the work under review.\n\
  \- Do not suggest fixes. Just explain, and label each concern BLOCKS or NICE-TO-HAVE."

dumbifyBlockReason :: Text -> Int -> Int -> Text -> Text
dumbifyBlockReason model thisRound maxRounds output =
  Text.concat
    [ "A ", model, " model (a small 'complexity canary') read the code you changed this turn, "
    , "with the full files as context, and explained it as follows (round "
    , Text.pack (show thisRound), " of ", Text.pack (show maxRounds)
    , "). You are the larger model and the final judge. Weigh its explanation:\n"
    , "  1. If it could NOT work out what the changed code DOES (a BLOCKS concern, a misread, or hedging about behaviour), the code is too complex. Apply a behaviour-preserving simplification (split a large dispatch into named functions, bundle threaded parameters into a record, add a domain-bridging comment, extract a capturing where-block). Your edits trigger a re-explanation. Do NOT change behaviour.\n"
    , "  2. If it understood the behaviour correctly, make no change and say so; the gate moves on. A NICE-TO-HAVE request for more comments when it already understood is advisory: weigh it, but you may decline and proceed rather than pile on prose.\n"
    , "Set CLAUDE_SKIP_DUMBIFY=1 to disable this gate.\n"
    , "\n--- canary explanation ---\n"
    , output
    , "\n--- end canary explanation ---"
    ]
