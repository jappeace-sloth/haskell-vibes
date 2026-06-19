-- | The vibes-gate executable: one binary, three hook subcommands.
--
-- Claude Code wires each hook to a subcommand in settings.json:
--   record     PostToolUse(Write|Edit|MultiEdit|NotebookEdit)
--   reset      UserPromptSubmit
--   stop-gate  Stop
module Main (main) where

import Gate.HookProtocol (HookEvent (sessionId), readHookEvent)
import Gate.RecordEdit (recordEdit)
import Gate.StopGate (runStopGate)
import Gate.TurnState (resetState, turnPaths)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["record"] -> recordEdit
    ["reset"] -> resetTurnState
    ["stop-gate"] -> runStopGate
    other -> do
      hPutStrLn stderr ("vibes-gate: unknown subcommand: " <> show other)
      hPutStrLn stderr "usage: vibes-gate (record | reset | stop-gate)"
      exitFailure

-- | UserPromptSubmit: wipe the previous turn's review stack and verify-done
-- flag so they do not leak into the new turn.
resetTurnState :: IO ()
resetTurnState = do
  event <- readHookEvent
  paths <- turnPaths (sessionId event)
  resetState paths
