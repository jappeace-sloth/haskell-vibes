-- | Running a nested @claude -p@ reviewer and surfacing its failures loudly.
--
-- Each Stop-gate phase shells out to a fresh @claude@ to review the turn. Two
-- rules from the shell gate are preserved here. First, the nested call is launched
-- with every gate phase disabled in its environment, so its own hooks cannot
-- re-enter this gate. Second, the gate FAILS LOUD: a reviewer that timed out,
-- crashed, or returned nothing is not read as a clean pass. It is logged and, on
-- its first occurrence this turn, blocks the Stop with a descriptive reason for
-- the model AND a user-visible systemMessage naming the weird exit status, so a
-- silently broken reviewer is never mistaken for a clean pass by either of them.
module Gate.NestedClaude
  ( Reviewer(..)
  , NestedResult(..)
  , GateFailure(..)
  , runNested
  , surfaceNestedFailure
  , surfaceGateFailure
  ) where

import Control.Exception.Safe (displayException, tryAny)
import Control.Monad (unless)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Gate.HookProtocol (BlockReason (BlockReason), blockAndExitWithNotice)
import Gate.SpawnAnnotation (annotateSpawn)
import Gate.TurnState (flagExists, writeFlag)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory)
import System.Process.Typed (byteStringInput, proc, readProcess, setEnv, setStdin, setWorkingDir)

-- | How to launch one nested reviewer. A read-only reviewer (the dumbify canary
-- and the rule reviewer) gets MCP disabled and only Read/Grep/Glob, skipping the
-- MCP cold-start cost; the critic is deliberately given neither, so it has full
-- tools to gather counter-evidence.
data Reviewer = Reviewer
  { reviewerModel :: Text
  , reviewerReadOnly :: Bool
  , reviewerTimeoutSecs :: Int
  , reviewerWorkdir :: Maybe FilePath
  }

-- | The outcome of a nested call. NestedBroken carries the exit code, whether
-- stdout was empty, and the captured stderr, so a failure can be described.
data NestedResult
  = NestedBroken Int Bool Text
  | NestedOutput Text

-- | Run @timeout N claude -p ... --model M@ feeding the prompt on stdin. The
-- timeout binary kills a hung reviewer (exit 124). A non-zero exit, an empty
-- stdout, or a spawn exception all count as broken.
runNested :: Reviewer -> Text -> IO NestedResult
runNested reviewer prompt = do
  baseEnv <- getEnvironment
  let configure =
        setStdin (byteStringInput (LazyByteString.fromStrict (encodeUtf8 prompt)))
          . setEnv (guardEnv baseEnv)
          . maybe id setWorkingDir (reviewerWorkdir reviewer)
      reviewerProcess = configure (proc "timeout" (timeoutArgs reviewer))
  outcome <- tryAny (annotateSpawn (nestedSpawnLabel reviewer) (readProcess reviewerProcess))
  pure $ case outcome of
    Left err -> NestedBroken 1 True (Text.pack (displayException err))
    Right (exitCode, out, errOut) -> interpret exitCode (decodeLazy out) (decodeLazy errOut)

interpret :: ExitCode -> Text -> Text -> NestedResult
interpret exitCode out err
  | nestedBroken exitCode out = NestedBroken (exitNumber exitCode) (emptyOutput out) err
  | otherwise = NestedOutput out

-- | Mirrors the shell @nested_call_broken@: a non-zero exit, or exit 0 with no
-- usable stdout, is broken; a reviewer that answered (even "OK") is not.
nestedBroken :: ExitCode -> Text -> Bool
nestedBroken ExitSuccess out = emptyOutput out
nestedBroken (ExitFailure _) _ = True

emptyOutput :: Text -> Bool
emptyOutput = Text.null . Text.strip

exitNumber :: ExitCode -> Int
exitNumber ExitSuccess = 0
exitNumber (ExitFailure n) = n

timeoutArgs :: Reviewer -> [String]
timeoutArgs reviewer =
  [show (reviewerTimeoutSecs reviewer), "claude", "-p"]
    <> (if reviewerReadOnly reviewer then readOnlyArgs else [])
    <> ["--model", Text.unpack (reviewerModel reviewer)]

readOnlyArgs :: [String]
readOnlyArgs = ["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "Read", "Grep", "Glob"]

-- | A label for the nested reviewer spawn, attached to any spawn failure so a
-- broken 'NestedResult' names which reviewer's process could not start (rather
-- than a bare @timeout: posix_spawnp@). Keyed by model, which distinguishes the
-- canary, rule reviewer and critic.
nestedSpawnLabel :: Reviewer -> String
nestedSpawnLabel reviewer =
  "timeout claude (nested " <> Text.unpack (reviewerModel reviewer) <> " reviewer)"

-- | Disable every gate phase in the nested reviewer's environment so its own
-- Stop hook cannot recurse into this gate.
guardEnv :: [(String, String)] -> [(String, String)]
guardEnv base =
  upsert "CLAUDE_SKIP_DUMBIFY" "1"
    (upsert "CLAUDE_SKIP_CRITIQUE" "1" (upsert "CLAUDE_SKIP_RULE_CHECK" "1" base))

upsert :: String -> String -> [(String, String)] -> [(String, String)]
upsert key value environment = (key, value) : filter ((/= key) . fst) environment

decodeLazy :: LazyByteString.ByteString -> Text
decodeLazy = decodeUtf8Lenient . LazyByteString.toStrict

-- | One gate failure described for its three audiences: the durable log, the
-- main-loop model, and the human watching. A record rather than positional
-- Text arguments so the reason and the notice cannot be swapped at a call site.
data GateFailure = GateFailure
  { failureHeadline :: Text
    -- ^ One line naming the failure in the durable log header.
  , failureLogBody :: Text
    -- ^ Detail recorded under the headline (stderr tail, paths).
  , failureBlockReason :: Text
    -- ^ Model-facing reason fed back when the Stop is blocked.
  , failureUserNotice :: Text
    -- ^ User-visible systemMessage shown alongside the block.
  }

-- | The shared fail-loud path: append the failure to the durable log and, on
-- its first occurrence this turn (tracked via the warn flag), block the Stop
-- with a reason for the model AND a user-visible notice (then exit). Later
-- occurrences only log and return, so a persistent failure surfaces once but
-- does not wedge the turn. Used for broken nested calls and for the critique's
-- empty dossier; anything the gate must never silently wave through.
surfaceGateFailure :: Text -> GateFailure -> FilePath -> IO ()
surfaceGateFailure session failure warnFlag = do
  appendFailureLog session (failureHeadline failure) (failureLogBody failure)
  alreadyWarned <- flagExists warnFlag
  unless alreadyWarned $ do
    writeFlag warnFlag
    blockAndExitWithNotice
      (BlockReason (failureBlockReason failure))
      (failureUserNotice failure)

-- | Log a broken nested call, and on its first occurrence this turn block the
-- Stop with a loud reason for the model and a user-visible notice (then exit).
-- On later occurrences it only logs and returns, so a permanently broken CLI
-- surfaces once but does not wedge the turn.
surfaceNestedFailure :: Text -> Text -> Text -> Int -> Bool -> Text -> FilePath -> IO ()
surfaceNestedFailure session phase model exitCode emptyOut stderrText =
  surfaceGateFailure session (nestedCallFailure phase model detail stderrText)
  where
    detail = failureDetail exitCode emptyOut

-- | Describe a broken nested call for 'surfaceGateFailure'.
nestedCallFailure :: Text -> Text -> Text -> Text -> GateFailure
nestedCallFailure phase model detail stderrText =
  GateFailure
    { failureHeadline = Text.concat ["nested call broke: phase=", phase, " model=", model, " ", detail]
    , failureLogBody = "--- stderr (last 20 lines) ---\n" <> stderrTail stderrText
    , failureBlockReason = failureReason phase model detail stderrText
    , failureUserNotice = failureNotice phase model detail
    }

-- | The short, user-visible companion to 'failureReason'. It names the phase,
-- the model, and the weird exit status so a watching human sees at once that a
-- reviewer broke and where to look, instead of mistaking the silence for a
-- clean pass. The default failure log path is named because it holds the detail.
failureNotice :: Text -> Text -> Text -> Text
failureNotice phase model detail =
  Text.concat
    [ "vibes-gate: the ", phase, " reviewer (", model, ") returned a bad exit status ("
    , detail, "), so this turn was NOT checked by it. Details in the gate failure log "
    , "($CLAUDE_GATE_FAILURE_LOG, default ~/.claude/gate-failures.log)."
    ]

failureDetail :: Int -> Bool -> Text
failureDetail exitCode emptyOut =
  "exit=" <> Text.pack (show exitCode)
    <> (if exitCode == 124 then " (timed out)" else "")
    <> (if emptyOut then ", empty output" else "")

failureReason :: Text -> Text -> Text -> Text -> Text
failureReason phase model detail stderrText =
  Text.concat
    [ "GATE INFRASTRUCTURE FAILURE in the ", phase, " phase: the nested ", model
    , " call returned no usable result (", detail, "), so this turn was NOT checked "
    , "by that phase. Find out why the reviewer could not run (timeout, auth, MCP, "
    , "model error) before trusting this turn. This loud warning fires once per turn; "
    , "you may continue after acknowledging it.\nLast stderr lines:\n"
    , stderrTail stderrText
    ]

stderrTail :: Text -> Text
stderrTail = Text.unlines . lastN 20 . Text.lines

lastN :: Int -> [a] -> [a]
lastN n xs = drop (length xs - n) xs

-- | Append a failure record to the durable log outside the per-turn state dir
-- (so it survives the per-prompt reset), overridable via CLAUDE_GATE_FAILURE_LOG.
appendFailureLog :: Text -> Text -> Text -> IO ()
appendFailureLog session headline body = do
  path <- failureLogPath
  createDirectoryIfMissing True (takeDirectory path)
  appendFile path $
    Text.unpack $
      Text.concat
        [ "=== gate failure: ", headline, " ===\n"
        , "session=", session, "\n"
        , body
        , "\n"
        ]

failureLogPath :: IO FilePath
failureLogPath = do
  override <- lookupEnv "CLAUDE_GATE_FAILURE_LOG"
  case override of
    Just path -> pure path
    Nothing -> do
      home <- lookupEnv "HOME"
      pure (fromMaybe "/tmp" home <> "/.claude/gate-failures.log")
