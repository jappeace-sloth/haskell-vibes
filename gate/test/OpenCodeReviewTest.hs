-- | Exercise the real gate with this test executable standing in for the model
-- CLI. No provider credentials or network are involved in these policy tests.
module OpenCodeReviewTest (tests, runFixture, runGate) where

import Control.Monad (forM_, when)
import Claude.Gate.RecordEdit (recordEdit)
import Claude.Gate.StopGate (runStopGate)
import Data.Aeson (FromJSON, ToJSON, Value (Object, String, Array, Number, Bool, Null), eitherDecode, encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import System.Directory (createFileLink, doesFileExist)
import System.Environment (getArgs, getEnv, getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed (byteStringInput, proc, readProcess, setEnv, setStdin, setWorkingDir)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

data Fixture = Fixture
  { fixtureDirectory :: FilePath
  , fixtureEnvironment :: [(String, String)]
  }

data ReviewCall = ReviewCall
  { callArguments :: [String]
  , callPrompt :: String
  , callNested :: String
  , callConfig :: Value
  } deriving stock (Generic)

instance FromJSON ReviewCall
instance ToJSON ReviewCall

tests :: TestTree
tests = testGroup "OpenCode reviewer backend"
  [ testCase "all phases inherit the GPT worker without invoking Claude" (allPhases [])
  , testCase "per-phase models do not inherit an incompatible worker variant" (allPhases
      [("OPENCODE_DUMBIFY_MODEL", "openai/canary"), ("OPENCODE_CRITIQUE_MODEL", "openai/critic"), ("OPENCODE_REVIEWER_MODEL", "openai/rules")])
  , testCase "invalid rule-review configuration leaves edits queued" invalidRuleModel
  , testCase "a provider error cannot approve a turn despite exit zero" (failedReview "error")
  , testCase "malformed JSON cannot approve a turn" (failedReview "malformed")
  , testCase "empty answer cannot approve a turn" (failedReview "empty")
  , testCase "unfinished answer cannot approve a turn" (failedReview "unfinished")
  ]

withFixture :: [(String, String)] -> (Fixture -> IO ()) -> IO ()
withFixture overrides action = withSystemTempDirectory "gpt-reviewer-test-" $ \directory -> do
  executable <- getExecutablePath
  createFileLink executable (directory </> "opencode")
  createFileLink executable (directory </> "claude")
  createFileLink executable (directory </> "claude-gate")
  writeFile (directory </> "calls") ""
  Bytes.writeFile (directory </> "transcript.jsonl") (encode (object
    ["type" .= ("assistant" :: Text), "message" .= object ["content" .= ("I implemented the change." :: Text)]]))
  environment <- getEnvironment
  path <- getEnv "PATH"
  action (Fixture directory (overrideEnvironment (overrides <>
    [ ("PATH", directory <> ":" <> path), ("TMPDIR", directory)
    , ("CLAUDE_GATE_BACKEND", "opencode"), ("OPENCODE_GATE_MODEL", "openai/gpt-6-astra"), ("OPENCODE_GATE_VARIANT", "high")
    , ("CLAUDE_SKIP_HOURS_CHECK", "1"), ("CLAUDE_SKIP_DUMBIFY", "0"), ("CLAUDE_SKIP_CRITIQUE", "0"), ("CLAUDE_SKIP_RULE_CHECK", "0")
    , ("CLAUDE_GATE_FAILURE_LOG", directory </> "failures"), ("GATE_REVIEW_CALLS", directory </> "calls")
    , ("OPENCODE_CONFIG_CONTENT", "{\"provider\":{\"fixture\":{\"name\":\"preserved\"}},\"agent\":{\"existing\":{\"description\":\"preserved\"}}}")
    ]) environment))

overrideEnvironment :: [(String, String)] -> [(String, String)] -> [(String, String)]
overrideEnvironment overrides original = foldr overrideVariable original overrides

overrideVariable :: (String, String) -> [(String, String)] -> [(String, String)]
overrideVariable (name, value) environment = (name, value) : filter ((/= name) . fst) environment

invokeGate :: Fixture -> String -> Value -> IO (ExitCode, Bytes.ByteString, Bytes.ByteString)
invokeGate fixture command payload = do
  executable <- fromMaybe (fixtureDirectory fixture </> "claude-gate") <$> lookupEnv "CLAUDE_GATE_TEST_BINARY"
  readProcess (setWorkingDir (fixtureDirectory fixture)
    (setEnv (fixtureEnvironment fixture)
      (setStdin (byteStringInput (encode payload)) (proc executable [command]))))

-- | Call the application's entry points in a subprocess, isolating stdin and
-- environment per test without recreating any of the gate's phase logic.
runGate :: IO ()
runGate = do
  arguments <- getArgs
  case arguments of
    ["record"] -> recordEdit
    ["stop-gate"] -> runStopGate
    unexpected -> ioError (userError ("Unsupported test gate command: " <> show unexpected))

stopPayload :: Fixture -> Value
stopPayload fixture = object
  [ "session_id" .= ("test" :: Text)
  , "transcript_path" .= (fixtureDirectory fixture </> "transcript.jsonl")
  ]

stopGate :: Fixture -> IO Value
stopGate fixture = do
  (status, output, diagnostic) <- invokeGate fixture "stop-gate" (stopPayload fixture)
  assertBool (Bytes.unpack diagnostic) (status == ExitSuccess)
  decodeOrFail output

recordCode :: Fixture -> IO ()
recordCode fixture = do
  (status, output, diagnostic) <- invokeGate fixture "record" (object
    [ "session_id" .= ("test" :: Text), "tool_name" .= ("ApplyPatch" :: Text)
    , "tool_input" .= object ["file_path" .= (fixtureDirectory fixture </> "changed.hs"), "patch" .= ("-old\n+new\n" :: Text)]
    ])
  assertBool (Bytes.unpack diagnostic) (status == ExitSuccess)
  output @?= ""

allPhases :: [(String, String)] -> Assertion
allPhases overrides = withFixture overrides $ \fixture -> do
  recordCode fixture
  canary <- stopGate fixture
  jsonAt ["decision"] canary @?= Just (String "block")
  verdict <- stopGate fixture
  -- Preliminary commentary and tool output contain findings; only the last
  -- completed step says OK, and only that step may determine approval.
  jsonAt ["decision"] verdict @?= Nothing
  jsonAt ["systemMessage"] verdict @?= Just (String "gate clear: dumbify critique rules")
  calls <- readCalls fixture
  length calls @?= 3
  forM_ (zip ["OPENCODE_DUMBIFY_MODEL", "OPENCODE_CRITIQUE_MODEL", "OPENCODE_REVIEWER_MODEL"] calls) $ \(phase, call) ->
    checkCall phase (lookup phase overrides) call

checkCall :: String -> Maybe String -> ReviewCall -> Assertion
checkCall phase override call = do
  let model = fromMaybe "openai/gpt-6-astra" override
  assertBool "uses the run command" (["run"] `isPrefixOf` callArguments call)
  argument "--format" (callArguments call) @?= Just "json"
  argument "--model" (callArguments call) @?= Just model
  argument "--variant" (callArguments call) @?= case override of
    Nothing -> Just "high"
    Just modelOverride -> if modelOverride == "openai/gpt-6-astra" then Just "high" else Nothing
  callNested call @?= "1"
  jsonAt ["small_model"] (callConfig call) @?= Just (String (Text.pack model))
  jsonAt ["provider", "fixture", "name"] (callConfig call) @?= Just (String "preserved")
  jsonAt ["agent", "existing", "description"] (callConfig call) @?= Just (String "preserved")
  agent <- maybe (ioError (userError "Reviewer did not select an agent")) pure (argument "--agent" (callArguments call))
  checkPermission agent "*" (if phase == "OPENCODE_CRITIQUE_MODEL" then "allow" else "deny") call
  checkPermission agent "task" "deny" call
  checkPermission agent "read" "allow" call
  assertBool "passes the actual review dossier on stdin" (length (callPrompt call) > 100)

checkPermission :: String -> Key -> Text -> ReviewCall -> Assertion
checkPermission agent tool permission call =
  jsonAt ["agent", Key.fromString agent, "permission", tool] (callConfig call) @?= Just (String permission)

argument :: String -> [String] -> Maybe String
argument name = listToMaybe . drop 1 . dropWhile (/= name)

jsonAt :: [Key] -> Value -> Maybe Value
jsonAt [] value = Just value
jsonAt (key : remaining) value = case value of
  Object fields -> KeyMap.lookup key fields >>= jsonAt remaining
  Array _values -> Nothing
  String _text -> Nothing
  Number _number -> Nothing
  Bool _boolean -> Nothing
  Null -> Nothing

readCalls :: Fixture -> IO [ReviewCall]
readCalls fixture = Bytes.readFile (fixtureDirectory fixture </> "calls") >>= traverse decodeOrFail . filter (not . Bytes.null) . Bytes.lines

decodeOrFail :: FromJSON value => Bytes.ByteString -> IO value
decodeOrFail encoded = either (ioError . userError) pure (eitherDecode encoded)

invalidRuleModel :: Assertion
invalidRuleModel = withFixture [("OPENCODE_REVIEWER_MODEL", "")] $ \fixture -> do
  recordCode fixture
  canary <- stopGate fixture
  jsonAt ["decision"] canary @?= Just (String "block")
  (status, output, diagnostic) <- invokeGate fixture "stop-gate" (stopPayload fixture)
  assertBool (Bytes.unpack (output <> diagnostic)) (status /= ExitSuccess)
  queued <- Bytes.readFile (fixtureDirectory fixture </> "claude-turn-state/test/edits.jsonl")
  assertBool "edits remain queued" (not (Bytes.null queued))
  doesFileExist (fixtureDirectory fixture </> "claude-turn-state/test/edits.processing") >>= (@?= False)

failedReview :: String -> Assertion
failedReview failure = withFixture [("REVIEW_FAILURE", failure)] $ \fixture -> do
  verdict <- stopGate fixture
  calls <- readCalls fixture
  length calls @?= 1
  jsonAt ["decision"] verdict @?= Just (String "block")
  when (failure == "error") $
    assertBool "provider error survives into feedback" ("Fixture login expired" `isInfixOf` Bytes.unpack (encode verdict))
  doesFileExist (fixtureDirectory fixture </> "claude-turn-state/test/critique-approved") >>= (@?= False)

-- | Mock `opencode run`, invoked through the symlink created by withFixture.
-- The real gate supplies the arguments, prompt, and child environment.
runFixture :: IO ()
runFixture = do
  arguments <- getArgs
  prompt <- getContents
  nested <- getEnv "OPENCODE_GATE_REVIEWER"
  configuration <- getEnv "OPENCODE_CONFIG_CONTENT" >>= decodeOrFail . Bytes.pack
  calls <- getEnv "GATE_REVIEW_CALLS"
  Bytes.appendFile calls (encode (ReviewCall arguments prompt nested configuration) <> "\n")
  failure <- lookupEnv "REVIEW_FAILURE"
  if failure == Just "malformed"
    then putStrLn "not json"
    else emitReview failure

emitReview :: Maybe String -> IO ()
emitReview failure = do
  emitPart "step_start" []
  emitPart "text" ["text" .= ("VIOLATIONS: preliminary observation, not a final verdict" :: Text)]
  emitPart "step_finish" ["reason" .= ("tool-calls" :: Text)]
  emitPart "step_start" []
  emitPart "tool_use" ["output" .= ("CHALLENGE: tool output is not a verdict" :: Text)]
  emitPart "text" ["text" .= (if failure == Just "empty" then "" else "OK" :: Text)]
  when (failure == Just "error") $ Bytes.putStrLn (encode (object
    [ "type" .= ("error" :: Text), "error" .= object ["message" .= ("Fixture login expired; sign in with opencode auth login." :: Text)] ]))
  when (failure /= Just "unfinished") (emitPart "step_finish" ["reason" .= ("stop" :: Text)])

emitPart :: Text -> [(Key, Value)] -> IO ()
emitPart event fields = Bytes.putStrLn (encode (object ["type" .= event, "part" .= object fields]))
