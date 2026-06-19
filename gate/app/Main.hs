-- | The vibes-gate executable: one binary, three hook subcommands.
--
-- Claude Code wires each hook to a subcommand in settings.json:
--   record     PostToolUse(Write|Edit|MultiEdit|NotebookEdit)
--   reset      UserPromptSubmit
--   stop-gate  Stop
module Main (main) where

import Control.Monad (join)
import Gate.HookProtocol (HookEvent (sessionId), readHookEvent)
import Gate.RecordEdit (recordEdit)
import Gate.StopGate (runStopGate)
import Gate.TurnState (resetState, turnPaths)
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
    )

-- | UserPromptSubmit: wipe the previous turn's review stack and verify-done
-- flag so they do not leak into the new turn.
resetTurnState :: IO ()
resetTurnState = do
  event <- readHookEvent
  paths <- turnPaths (sessionId event)
  resetState paths
