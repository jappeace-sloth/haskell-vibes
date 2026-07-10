module Main (main) where

import Control.Exception (ErrorCall (ErrorCall), SomeException, displayException, throwIO, try)
import Data.Aeson (Result (Success), Value, eitherDecode, eitherDecodeStrict, encode, fromJSON, toJSON)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Char8 qualified as ByteString
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Gate.Corpus (selectSkills)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Gate.Critique
  ( CritiqueDossier (DossierReady, EmptyDossier)
  , EditPresence (EditsRecorded, NoEditsRecorded)
  , RoundBudget (RoundBudget)
  , classifyDossier
  , critiqueAnchor
  , critiqueDiffBlock
  , recentClaims
  , retryWhileEmpty
  )
import Gate.DiffRender (renderDiffs)
import Gate.Edit (Edit (..), Replacement (..), editFilePath, parseEditFromTool)
import Gate.RecordEdit (SkipReason (..), pathSkipReason)
import Gate.ReviewPrompt (hasViolations)
import Gate.SpawnAnnotation (annotateSpawn)
import Gate.Transcript (turnAssistantText)
import Gate.TurnState (readCounter, writeCounter)
import Hedgehog (Gen, Property, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Hedgehog (testProperty)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
    , editPropertyTests
    , critiqueDiffTests
    , recentClaimsTests
    , critiqueAnchorTests
    , claimsRetryTests
    , dossierTests
    , counterTests
    , spawnAnnotationTests
    ]

-- The claims blob accumulates across a turn's critique rounds and is
-- chronological, so when it exceeds the budget the critic must keep the NEWEST
-- claims (the current round) and drop the oldest. A front trim (the old
-- Text.take) kept the oldest and dropped the newest, which is what fed the critic
-- stale claims. These assert the tail survives and the head is dropped.

recentClaimsTests :: TestTree
recentClaimsTests =
  testGroup
    "recentClaims"
    [ testCase "keeps the newest claims and drops the oldest over budget" $ do
        let oldest = "OLDEST-round-1-run-A"
            newest = "NEWEST-round-3-run-C"
            blob = oldest <> Text.replicate 200 "x" <> newest
            trimmed = recentClaims (Text.length newest + 20) blob
        assertBool "the current round's claim survives" (Text.isInfixOf newest trimmed)
        assertBool "the stale first round's claim is dropped" (not (Text.isInfixOf oldest trimmed))
    , testCase "claims within budget pass through unchanged" $
        recentClaims 1000 "short claim" @?= "short claim"
    ]

-- The anchor threads the round and the commit history into the prompt. The one
-- piece of logic (not static text) is that a missing history is turned into an
-- explicit placeholder rather than dropped, and a present history is carried
-- through verbatim so the critic actually sees the real commit order.

critiqueAnchorTests :: TestTree
critiqueAnchorTests =
  testGroup
    "critiqueAnchor"
    [ testCase "a present commit history is carried through verbatim" $
        assertBool
          "the supplied history appears in the anchor"
          (Text.isInfixOf "deadbeef 2026-07-10T12:00:00Z fix the thing" (critiqueAnchor (RoundBudget 2 3) (Just "deadbeef 2026-07-10T12:00:00Z fix the thing")))
    , testCase "a missing history becomes an explicit placeholder, not a blank" $
        assertBool
          "the placeholder names the missing history"
          (Text.isInfixOf "unavailable" (critiqueAnchor (RoundBudget 1 2) Nothing))
    ]

-- The transcript can lag the Stop hook (the final assistant message flushes
-- after the hook fires), so the claims read polls via 'retryWhileEmpty'. These
-- drive the real retry loop with a scripted sequence of reads: it must return
-- at the first non-blank read, keep polling past blank ones, and hand back the
-- final blank result when the budget runs out so the caller can fail loud.

claimsRetryTests :: TestTree
claimsRetryTests =
  testGroup
    "retryWhileEmpty"
    [ testCase "returns at the first non-blank read without extra attempts" $ do
        (result, reads') <- scriptedRetry 5 ["claims right away"]
        result @?= "claims right away"
        reads' @?= 1
    , testCase "polls past blank reads until text appears" $ do
        (result, reads') <- scriptedRetry 5 ["", "  \n  ", "late claims"]
        result @?= "late claims"
        reads' @?= 3
    , testCase "gives up blank after the attempt budget so the caller can fail loud" $ do
        (result, reads') <- scriptedRetry 3 ["", "", "", "", ""]
        result @?= ""
        reads' @?= 3
    ]

-- | Drive 'retryWhileEmpty' (with no pause between attempts) through a
-- scripted sequence of reads, returning the final result and the number of
-- reads it consumed.
scriptedRetry :: Int -> [Text] -> IO (Text, Int)
scriptedRetry attempts script = do
  counter <- newIORef (0 :: Int)
  result <- retryWhileEmpty attempts 0 (nextScriptedRead counter script)
  reads' <- readIORef counter
  pure (result, reads')

nextScriptedRead :: IORef Int -> [Text] -> IO Text
nextScriptedRead counter script = do
  index <- readIORef counter
  writeIORef counter (index + 1)
  case drop index script of
    [] -> throwIO (ErrorCall "scripted retry consumed more reads than the test provided")
    next : _ -> pure next

-- The empty-dossier rule: a critic spawned with neither claims nor edits can
-- only answer OK, and that OK must never be recorded as approval. The
-- classification decides between failing loud and spawning the critic, so a
-- wrong verdict here either wedges healthy turns or silently green-stamps
-- unchecked ones.

dossierTests :: TestTree
dossierTests =
  testGroup
    "classifyDossier"
    [ testCase "no claims and no edits is an empty dossier" $
        classifyDossier "" NoEditsRecorded @?= EmptyDossier
    , testCase "whitespace-only claims count as no claims" $
        classifyDossier "  \n \t " NoEditsRecorded @?= EmptyDossier
    , testCase "claims alone are enough to critique" $
        classifyDossier "I fixed the bug" NoEditsRecorded @?= DossierReady
    , testCase "edits alone are enough to critique" $
        classifyDossier "" EditsRecorded @?= DossierReady
    ]

-- A spawn that fails (a missing binary, or a /bin symlink left dangling by a
-- nix GC) must not vanish into a bare posix_spawnp error: 'annotateSpawn' tags
-- the exception with its command so an uncaught crash, or a displayException of
-- a caught one, names the call site. The assertion drives a real exception
-- through 'annotateSpawn' and checks the label survives into displayException.

spawnAnnotationTests :: TestTree
spawnAnnotationTests =
  testGroup
    "annotateSpawn"
    [ testCase "a failing spawn carries its call site into displayException" $ do
        let spawnLabel = "git -C /x rev-parse --show-toplevel"
        outcome <- try (annotateSpawn spawnLabel (throwIO (ErrorCall "spawn blew up")))
        case (outcome :: Either SomeException ()) of
          Right () -> assertFailure "expected the wrapped action to throw"
          Left err ->
            assertBool
              "displayException names the spawn call site"
              (spawnLabel `isInfixOf` displayException err)
    ]

-- A read-then-write on the same counter file, the exact sequence handleChallenge
-- runs on critique-round. With a lazy 'readFile' inside 'readCounter' the read
-- handle is still open when 'writeCounter' opens the path in WriteMode, and GHC's
-- single-writer file lock aborts with "resource busy (file is locked)". The
-- assertion is that the cycle completes and round-trips the value.
counterTests :: TestTree
counterTests =
  testGroup
    "TurnState counters"
    [ testCase "readCounter then writeCounter on the same path does not lock" $ do
        dir <- getTemporaryDirectory
        let path = dir </> "vibes-gate-counter-roundtrip"
        writeCounter path 1
        previous <- readCounter path
        writeCounter path (previous + 1)
        final <- readCounter path
        final @?= 2
    ]

-- The critique claims-extraction end to end: write a transcript file and ask the
-- real 'turnAssistantText' for the assistant prose since the last real user
-- prompt. This exercises line parsing, "since the last real user prompt", and
-- text-block extraction together, which is where the gnarly logic lives.

transcriptTests :: TestTree
transcriptTests =
  testGroup
    "turnAssistantText"
    [ testCase "collects assistant text after the last user prompt" $ do
        claims <- claimsFor "after" [userPrompt, assistantSays "I fixed the bug"]
        claims @?= "I fixed the bug"
    , testCase "ignores assistant text before the last user prompt" $ do
        -- The first claim is from a previous turn; only the latest turn counts.
        claims <- claimsFor "before" [assistantSays "old claim", userPrompt, assistantSays "new claim"]
        claims @?= "new claim"
    , testCase "joins multiple assistant turns with newlines" $ do
        claims <- claimsFor "multi" [userPrompt, assistantSays "first", assistantSays "second"]
        claims @?= "first\nsecond"
    , testCase "a tool-reply user entry is not a turn boundary" $ do
        -- The array-content user entry is a tool result, not a real prompt, so
        -- the earlier claim is still in this turn.
        claims <- claimsFor "toolreply" [userPrompt, assistantSays "before tool", toolResult, assistantSays "after tool"]
        claims @?= "before tool\nafter tool"
    ]

claimsFor :: String -> [Text] -> IO Text
claimsFor name transcriptLines = do
  tmp <- getTemporaryDirectory
  let path = tmp </> ("vibes-gate-test-" <> name <> ".jsonl")
  writeFile path (Text.unpack (Text.unlines transcriptLines))
  turnAssistantText path

userPrompt :: Text
userPrompt = "{\"type\":\"user\",\"message\":{\"content\":\"do the thing\"}}"

toolResult :: Text
toolResult = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}}"

assistantSays :: Text -> Text
assistantSays text =
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\""
    <> text
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

-- The critic runs on every turn, including conversational ones with no edits. On
-- such a turn there is no review stack on disk, so the diff block must come back
-- as the placeholder WITHOUT reading (and crashing on) the absent stack file.
-- This is the regression: the old code read the stack unconditionally and died on
-- a missing edits.jsonl, which silently killed the whole critique phase.

critiqueDiffTests :: TestTree
critiqueDiffTests =
  testGroup
    "critiqueDiffBlock"
    [ testCase "a no-edit turn yields the placeholder without touching the stack" $ do
        block <- critiqueDiffBlock NoEditsRecorded "/no/such/edits.jsonl"
        block @?= "(no file edits this turn)"
    , testCase "an edited turn renders the recorded diff" $ do
        edit <- parsedEdit "Edit" "{\"file_path\":\"src/Foo.hs\",\"old_string\":\"old line\",\"new_string\":\"new line\"}"
        stackPath <- writeStack "critique-edits" [edit]
        block <- critiqueDiffBlock EditsRecorded stackPath
        assertBool "new text appears in the diff block" (Text.isInfixOf "new line" block)
    ]

-- | Write edits to a stack file in the one-JSON-per-line form record-edit uses,
-- so the reader under test sees exactly what production writes.
writeStack :: String -> [Edit] -> IO FilePath
writeStack name edits = do
  tmp <- getTemporaryDirectory
  let path = tmp </> ("vibes-gate-test-" <> name <> ".jsonl")
  LazyByteString.writeFile path (LazyByteString.intercalate "\n" (map encode edits))
  pure path

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

-- The JSON instances the two hooks rely on must satisfy
-- fromJSON (toJSON e) == Success e for every edit shape, checked over
-- generated inputs rather than the few hand-written fixtures above.

editPropertyTests :: TestTree
editPropertyTests =
  testGroup
    "edit JSON property"
    [ testProperty "fromJSON . toJSON == Success" editJsonRoundTrip
    ]

editJsonRoundTrip :: Property
editJsonRoundTrip = property $ do
  edit <- forAll genEdit
  fromJSON (toJSON edit) === Success edit

genEdit :: Gen Edit
genEdit =
  Gen.choice
    [ SingleEdit <$> genPath <*> genReplacement
    , MultiEditFile <$> genPath <*> Gen.list (Range.linear 0 4) genReplacement
    , WriteFileContent <$> genPath <*> genText
    , NotebookCellSource <$> genPath <*> genText
    ]

genReplacement :: Gen Replacement
genReplacement = Replacement <$> genText <*> genText

genText :: Gen Text
genText = Gen.text (Range.linear 0 40) Gen.unicode

genPath :: Gen FilePath
genPath = Gen.string (Range.linear 1 30) Gen.alphaNum
