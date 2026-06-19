module Main (main) where

import Data.Aeson (Value, eitherDecode, eitherDecodeStrict, encode)
import Data.ByteString.Char8 qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Gate.Corpus (selectSkills)
import Gate.DiffRender (renderDiffs)
import Gate.Edit (Edit, editFilePath, parseEditFromTool)
import Gate.RecordEdit (SkipReason (..), pathSkipReason)
import Gate.ReviewPrompt (hasViolations)
import Gate.Transcript (turnTouchedState)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "vibes-gate"
    [ transcriptTests
    , skillSelectionTests
    , skipReasonTests
    , violationTests
    , editRoundTripTests
    ]

-- The Phase B decision end to end: write a transcript file and ask the real
-- 'turnTouchedState' whether the turn touched state. This exercises line
-- parsing, "since the last real user prompt", and the state-touching set
-- together, which is where the gnarly logic lives.

transcriptTests :: TestTree
transcriptTests =
  testGroup
    "turnTouchedState"
    [ testCase "state tool after the last user prompt counts" $ do
        touched <- touchedFor "after-bash" [userPrompt, assistantTool "Bash"]
        touched @?= True
    , testCase "state tool only before the last prompt does not count" $ do
        -- The Bash is before the prompt; after it only a read-only tool.
        touched <- touchedFor "before-bash" [assistantTool "Bash", userPrompt, assistantTool "Read"]
        touched @?= False
    , testCase "an mcp tool after the prompt counts" $ do
        touched <- touchedFor "mcp" [userPrompt, assistantTool "mcp__hoogle__search"]
        touched @?= True
    , testCase "a turn with no tools does not count" $ do
        touched <- touchedFor "no-tools" [userPrompt]
        touched @?= False
    ]

touchedFor :: String -> [Text] -> IO Bool
touchedFor name transcriptLines = do
  tmp <- getTemporaryDirectory
  let path = tmp </> ("vibes-gate-test-" <> name <> ".jsonl")
  writeFile path (Text.unpack (Text.unlines transcriptLines))
  turnTouchedState path

userPrompt :: Text
userPrompt = "{\"type\":\"user\",\"message\":{\"content\":\"do the thing\"}}"

assistantTool :: Text -> Text
assistantTool toolName =
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\""
    <> toolName
    <> "\"}]}}"

-- Skill selection maps touched extensions to the relevant language skills.

skillSelectionTests :: TestTree
skillSelectionTests =
  testGroup
    "selectSkills"
    [ testCase "haskell sources pull in the haskell skills" $
        selectSkills ["src/Foo.hs"]
          @?= ["error-messages", "haskell-backpack", "haskell-project", "unwitch-conversions", "verify-test-fails"]
    , testCase "nix files pull in the nix skills" $
        selectSkills ["default.nix"] @?= ["ci-nix", "nix"]
    , testCase "unrelated files select nothing" $
        selectSkills ["notes.md"] @?= []
    , testCase "results are deduplicated across many files" $
        selectSkills ["A.hs", "B.hs", "x.cabal"]
          @?= ["error-messages", "haskell-backpack", "haskell-project", "unwitch-conversions", "verify-test-fails"]
    ]

-- The record filter: which paths are skipped and why.

skipReasonTests :: TestTree
skipReasonTests =
  testGroup
    "pathSkipReason"
    [ testCase "haskell source is reviewed" $ pathSkipReason "src/Foo.hs" @?= Nothing
    , testCase "json is skipped as binary-ish" $ pathSkipReason "package.json" @?= Just SkipBinaryExtension
    , testCase "archives are skipped" $ pathSkipReason "bundle.tar.gz" @?= Just SkipArchive
    , testCase "build artifacts under dist-newstyle are skipped" $
        pathSkipReason "/home/x/dist-newstyle/build/Foo.hs" @?= Just SkipBuildArtifact
    , testCase "the result symlink is skipped" $ pathSkipReason "/home/x/result" @?= Just SkipBuildArtifact
    ]

-- Reviewer-reply parsing: only a VIOLATION line means findings.

violationTests :: TestTree
violationTests =
  testGroup
    "hasViolations"
    [ testCase "the clean reply OK is not a violation" $ hasViolations "OK\n" @?= False
    , testCase "empty output is not a violation" $ hasViolations "" @?= False
    , testCase "a VIOLATION block is a violation" $
        hasViolations "VIOLATION: used a wildcard\nRULE: \"...\"\n" @?= True
    , testCase "the word violation mid-line is not a violation" $
        hasViolations "no violation here\n" @?= False
    ]

-- Edits survive the persist/reload round trip the two hooks rely on, and the
-- reconstructed diff shows the new text under the right label.

editRoundTripTests :: TestTree
editRoundTripTests =
  testGroup
    "edit persistence"
    [ testCase "an Edit round-trips and renders its new text" $ do
        edit <- parsedEdit "Edit" "{\"file_path\":\"src/Foo.hs\",\"old_string\":\"old line\",\"new_string\":\"new line\"}"
        reloaded <- reencode edit
        editFilePath reloaded @?= "src/Foo.hs"
        let rendered = renderDiffs [reloaded]
        assertBool "new text under --- with ---" (Text.isInfixOf "--- with ---\nnew line" rendered)
        assertBool "old text under --- replaced ---" (Text.isInfixOf "--- replaced ---\nold line" rendered)
    , testCase "a Write round-trips and renders its content" $ do
        edit <- parsedEdit "Write" "{\"file_path\":\"a.txt\",\"content\":\"hello body\"}"
        reloaded <- reencode edit
        assertBool "content under --- new content ---" (Text.isInfixOf "--- new content ---\nhello body" (renderDiffs [reloaded]))
    ]

parsedEdit :: Text -> ByteString.ByteString -> IO Edit
parsedEdit tool inputJson = case eitherDecodeStrict inputJson of
  Left err -> fail ("test fixture is not valid JSON: " <> err)
  Right (value :: Value) -> case parseEditFromTool tool value of
    Left err -> fail ("parseEditFromTool failed: " <> err)
    Right edit -> pure edit

reencode :: Edit -> IO Edit
reencode edit = case eitherDecode (encode edit) of
  Left err -> fail ("edit did not round-trip: " <> err)
  Right reloaded -> pure reloaded
