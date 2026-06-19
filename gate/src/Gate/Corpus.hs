-- | Assemble the rules corpus the reviewer is checked against.
--
-- The corpus is the global CLAUDE.md, the project CLAUDE.md (if it is a
-- different file), and the SKILL.md of each skill whose rules could apply to
-- the file types touched this turn. Attaching every skill was almost all of the
-- old prompt and pure latency, so only language skills matching the touched
-- extensions are selected; the two CLAUDE.md files are always included.
module Gate.Corpus
  ( selectSkills
  , buildCorpus
  ) where

import Data.List (isSuffixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import System.Directory (doesFileExist, getHomeDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.Process.Typed (proc, readProcess)

-- | Skill names whose rules are relevant to the touched file types, sorted and
-- deduplicated. Pure so the mapping can be tested directly.
selectSkills :: [FilePath] -> [Text]
selectSkills = sort . nub . concatMap skillsForPath

skillsForPath :: FilePath -> [Text]
skillsForPath path
  | any (`isSuffixOf` path) haskellExtensions = haskellSkills
  | ".nix" `isSuffixOf` path = nixSkills
  | otherwise = []

haskellExtensions :: [FilePath]
haskellExtensions = [".hs", ".lhs", ".hsig", ".cabal"]

haskellSkills :: [Text]
haskellSkills =
  ["haskell-project", "haskell-backpack", "unwitch-conversions", "verify-test-fails", "error-messages"]

nixSkills :: [Text]
nixSkills = ["nix", "ci-nix"]

-- | Build the corpus text for the files touched this turn. Reads the two
-- CLAUDE.md files and the selected skills from disk.
buildCorpus :: [FilePath] -> IO Text
buildCorpus touchedPaths = do
  home <- getHomeDirectory
  let globalClaude = home </> ".claude" </> "CLAUDE.md"
  globalSection <- fileSection ("=== " <> Text.pack globalClaude <> " ===") globalClaude
  projectSection <- projectClaudeSection globalClaude touchedPaths
  skillSections <- mapM (skillSection home) (selectSkills touchedPaths)
  pure (Text.concat (globalSection <> projectSection <> concat skillSections))

-- | The project CLAUDE.md, resolved from the git root of the first touched
-- file, included only if it exists and is a different file from the global one.
projectClaudeSection :: FilePath -> [FilePath] -> IO [Text]
projectClaudeSection globalClaude touchedPaths = case touchedPaths of
  [] -> pure []
  (firstFile : _) -> do
    maybeRoot <- gitRoot (takeDirectory firstFile)
    case maybeRoot of
      Nothing -> pure []
      Just root ->
        let projectClaude = root </> "CLAUDE.md"
         in if projectClaude == globalClaude
              then pure []
              else fileSection ("=== " <> Text.pack projectClaude <> " ===") projectClaude

skillSection :: FilePath -> Text -> IO [Text]
skillSection home skillName =
  fileSection
    ("=== skill: " <> skillName <> " ===")
    (home </> ".claude" </> "skills" </> Text.unpack skillName </> "SKILL.md")

-- | A labelled section for a file, or nothing if the file is absent. Absence is
-- expected (not every skill or project has the file), so it is a legitimate
-- empty result rather than a swallowed error.
fileSection :: Text -> FilePath -> IO [Text]
fileSection heading path = do
  present <- doesFileExist path
  if present
    then do
      body <- TextIO.readFile path
      pure ["\n" <> heading <> "\n" <> body]
    else pure []

-- | The git work tree root containing a directory, or Nothing if it is not in a
-- repository.
gitRoot :: FilePath -> IO (Maybe FilePath)
gitRoot dir = do
  (exitCode, out, _err) <- readProcess (proc "git" ["-C", dir, "rev-parse", "--show-toplevel"])
  pure $ case LazyChar8.lines out of
    (root : _) | isSuccess exitCode && not (LazyChar8.null root) -> Just (LazyChar8.unpack root)
    _noRoot -> Nothing

isSuccess :: ExitCode -> Bool
isSuccess = \case
  ExitSuccess -> True
  ExitFailure _ -> False
