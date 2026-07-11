-- | The PostToolUse half of the gate: record an edit onto the per-turn review
-- stack, near-instantly, so the Stop gate can review the whole turn's diffs in
-- one pass. This never blocks the agent and never reviews anything itself.
module Claude.Gate.RecordEdit
  ( recordEdit
  , editTools
  , pathSkipReason
  , SkipReason(..)
  , maxRecordedFileBytes
  ) where

import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf, isSuffixOf)
import Data.Text (Text)
import Claude.Gate.Edit (Edit, editFilePath, parseEditFromTool)
import Claude.Gate.HookProtocol (HookEvent (sessionId, toolInput, toolName), readHookEvent)
import Claude.Gate.TurnState (TurnPaths (reviewStack), ensureStateDir, turnPaths)
import System.Directory (doesFileExist, getFileSize)
import System.Environment (lookupEnv)

-- | The tools whose edits we record. Matches the PostToolUse matcher in
-- settings.json; any other tool name is simply not an edit event.
editTools :: [Text]
editTools = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

-- | Files larger than this are skipped so a huge generated write does not burn
-- review tokens. Matches the 50 KB cutoff the shell hook used.
maxRecordedFileBytes :: Integer
maxRecordedFileBytes = 50_000

-- | Why an edit was not recorded. Kept as data (rather than a bare Bool) so the
-- reason is greppable and testable, even though the hook acts the same for all
-- of them: it skips silently, because a skipped file is an intended no-op, not
-- a failure.
data SkipReason
  = SkipBinaryExtension
  | SkipArchive
  | SkipBuildArtifact
  deriving stock (Eq, Show)

-- | Decide, from the path alone, whether prose/style rules could apply. Returns
-- the reason to skip, or Nothing to consider the file. Pure so it can be tested
-- without touching the filesystem.
pathSkipReason :: FilePath -> Maybe SkipReason
pathSkipReason path
  | any (`isSuffixOf` path) binaryExtensions = Just SkipBinaryExtension
  | any (`isSuffixOf` path) archiveExtensions = Just SkipArchive
  | any (`isInfixOf` path) buildArtifactInfixes = Just SkipBuildArtifact
  | "/result" `isSuffixOf` path = Just SkipBuildArtifact
  | "/result-" `isInfixOf` path = Just SkipBuildArtifact
  | otherwise = Nothing

binaryExtensions :: [FilePath]
binaryExtensions =
  [ ".lock", ".json", ".csv", ".tsv", ".png", ".jpg", ".jpeg", ".gif"
  , ".pdf", ".ico", ".svg", ".sqlite", ".db", ".so", ".dylib", ".exe", ".bin"
  ]

archiveExtensions :: [FilePath]
archiveExtensions = [".zip", ".tar", ".tar.gz", ".tgz", ".bz2", ".xz", ".7z", ".rar"]

buildArtifactInfixes :: [FilePath]
buildArtifactInfixes = ["/node_modules/", "/.git/", "/dist-newstyle/"]

-- | Entry point for the @record@ subcommand. Reads the PostToolUse event,
-- applies the same filters the shell hook did, and appends the edit as one JSON
-- line to the review stack.
recordEdit :: IO ()
recordEdit = do
  -- Recording respects the rule-review skip flag because the only consumer of
  -- the review stack is the Stop gate's Phase A rule review. With review off
  -- nothing ever reads the stack, so recording would be pure overhead.
  disabled <- ruleCheckDisabled
  unless disabled $ do
    event <- readHookEvent
    case (toolName event, toolInput event) of
      (Just tool, Just input)
        | tool `elem` editTools ->
            case parseEditFromTool tool input of
              Left err -> error ("claude-gate record: malformed " <> show tool <> " input: " <> err)
              Right edit -> recordIfRelevant (sessionId event) edit
      _notAnEditEvent -> pure ()

ruleCheckDisabled :: IO Bool
ruleCheckDisabled = (== Just "1") <$> lookupEnv "CLAUDE_SKIP_RULE_CHECK"

recordIfRelevant :: Text -> Edit -> IO ()
recordIfRelevant session edit = case pathSkipReason path of
  Just SkipBinaryExtension -> pure ()
  Just SkipArchive -> pure ()
  Just SkipBuildArtifact -> pure ()
  Nothing -> do
    isRegularFile <- doesFileExist path
    when isRegularFile $ do
      tooBig <- aboveSizeLimit path
      binary <- looksBinary path
      when (not tooBig && not binary) (appendEdit session edit)
  where
    path = editFilePath edit

aboveSizeLimit :: FilePath -> IO Bool
aboveSizeLimit path = (> maxRecordedFileBytes) <$> getFileSize path

-- | Cheap binary heuristic matching the shell hook: a NUL byte in the first
-- 8 KB means binary.
looksBinary :: FilePath -> IO Bool
looksBinary path = do
  prefix <- ByteString.take 8192 <$> ByteString.readFile path
  pure (ByteString.elem 0 prefix)

appendEdit :: Text -> Edit -> IO ()
appendEdit session edit = do
  paths <- turnPaths session
  ensureStateDir paths
  LazyByteString.appendFile (reviewStack paths) (Aeson.encode edit <> "\n")
