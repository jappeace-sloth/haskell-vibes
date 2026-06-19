-- | The vibes-gate executable: one binary, four subcommands.
--
-- Claude Code wires each hook to a subcommand in settings.json:
--   record     PostToolUse(Write|Edit|MultiEdit|NotebookEdit)
--   reset      UserPromptSubmit
--   stop-gate  Stop
--
-- The fourth, @critique@, is not wired to a hook: it runs ONLY the adversarial
-- critique phase against the same hook event on stdin, so the nested reviewer
-- call can be exercised and debugged in isolation (e.g. to see whether the
-- nested @claude@ authenticates and answers, rather than hanging) without the
-- dumbify and rule-review phases around it.
module Main (main) where

import Control.Monad (join)
import Gate.Critique (runCritique)
import Gate.HookProtocol (HookEvent (sessionId, transcriptPath), readHookEvent)
import Gate.RecordEdit (recordEdit)
import Gate.StopGate (runStopGate)
import Gate.TurnState (ensureStateDir, resetState, turnPaths)
import Options.Applicative

main :: IO ()
-- Each subcommand parses to the IO action for its hook, so execParser yields an
-- IO (IO ()); join runs the chosen action.
main = join (execParser (info (subcommands <**> helper) description))

description :: InfoMod a
description = fullDesc <> progDesc "Claude Code end-of-turn gate hooks (record, reset, stop-gate)"

-- | Each subcommand parses no options and yields the IO action for its hook.
subcommands :: Parser (IO ())
subcommands =
  subparser
    ( command "record" (info (pure recordEdit) (progDesc "PostToolUse: record an edit onto the review stack"))
        <> command "reset" (info (pure resetTurnState) (progDesc "UserPromptSubmit: wipe the previous turn's state"))
        <> command "stop-gate" (info (pure runStopGate) (progDesc "Stop: rule review, then verification"))
        <> command "critique" (info (pure runCritiqueOnly) (progDesc "Run only the adversarial critique phase (for debugging the nested reviewer)"))
    )

-- | Run the critique phase standalone against the hook event on stdin. This is
-- the same call 'runStopGate' makes for phase 1, lifted out of the phase chain
-- so the nested reviewer can be reproduced on its own. It reads the hook event,
-- prepares the turn state dir, and runs the critique against the live transcript
-- and the edits already recorded this turn.
runCritiqueOnly :: IO ()
runCritiqueOnly = do
  event <- readHookEvent
  paths <- turnPaths (sessionId event)
  ensureStateDir paths
  runCritique (sessionId event) (transcriptPath event) paths

-- | UserPromptSubmit: wipe the previous turn's review stack and verify-done
-- flag so they do not leak into the new turn.
resetTurnState :: IO ()
resetTurnState = do
  event <- readHookEvent
  paths <- turnPaths (sessionId event)
  resetState paths
