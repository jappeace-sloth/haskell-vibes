-- | Resolving the git work-tree root a reviewer should run in.
--
-- The dumbify canary and the critic run in the repository so they can read code
-- and (the critic) run tests. The root is taken from the first edited file;
-- the critic falls back to the gate's own working directory on a turn with no
-- file edits.
module Gate.Repo
  ( gitRoot
  , repoForFiles
  , repoForFilesOrCwd
  , commitHistory
  ) where

import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory)
import System.Process.Typed (proc, readProcess)

import Gate.SpawnAnnotation (annotateSpawn)

-- | The git work-tree root containing a directory. 'Nothing' when the directory
-- is not in a repository, or when @git@ is not on @PATH@ at all.
--
-- Decision: guard the spawn with 'findExecutable' rather than spawning blind.
-- A missing @git@, or a @\/bin\/git@ symlink left dangling by a nix
-- garbage-collection, otherwise crashes the whole Stop hook on @posix_spawnp@;
-- declining to resolve a root lets the caller skip that reviewer instead. This
-- mirrors the @findExecutable "claude"@ guard the reviewers already use.
-- Alternative considered: catch the spawn exception; rejected because the
-- pre-flight check keeps the not-installed path explicit and never swallows a
-- genuine spawn failure of a @git@ that IS present.
gitRoot :: FilePath -> IO (Maybe FilePath)
gitRoot dir = do
  gitOnPath <- findExecutable "git"
  case gitOnPath of
    Nothing -> pure Nothing
    Just _ -> do
      (exitCode, out, _err) <-
        annotateSpawn ("git -C " <> dir <> " rev-parse --show-toplevel") $
          readProcess (proc "git" ["-C", dir, "rev-parse", "--show-toplevel"])
      pure (parseTopLevel exitCode out)

-- | The first line of @git rev-parse --show-toplevel@ output is the work-tree
-- root on success; a failing exit or empty output means not-a-repository.
parseTopLevel :: ExitCode -> LazyChar8.ByteString -> Maybe FilePath
parseTopLevel exitCode out =
  case LazyChar8.lines out of
    (root : _) ->
      if isSuccess exitCode && not (LazyChar8.null root)
        then Just (LazyChar8.unpack root)
        else Nothing
    [] -> Nothing

isSuccess :: ExitCode -> Bool
isSuccess = \case
  ExitSuccess -> True
  ExitFailure _ -> False

-- | The repo's recent commit history, newest first, one commit per line as
-- @\<full-sha\> \<committer-ISO-8601-date\> \<subject\>@. The first line is HEAD.
-- The critic runs with full tools and cross-checks external CI runs; handed the
-- real commit order and each commit's timestamp it can pin a run to a commit by
-- its sha instead of reconstructing the order from run start times (which are not
-- commit order: a run can start on an older HEAD and finish after a newer commit
-- exists) and pinning runs to the wrong commits. 'Nothing' when the directory is
-- not a work tree, or when @git@ is not on @PATH@ (same guard as 'gitRoot').
commitHistory :: FilePath -> IO (Maybe Text)
commitHistory dir = do
  gitOnPath <- findExecutable "git"
  case gitOnPath of
    Nothing -> pure Nothing
    Just _ -> do
      -- 15 commits: enough to cover a turn's worth of recent work (so the critic
      -- can place the runs it checks) without bloating the prompt with ancient
      -- history the critique will never reference.
      (exitCode, out, _err) <-
        annotateSpawn ("git -C " <> dir <> " log -n 15 --format=%H %cI %s") $
          readProcess (proc "git" ["-C", dir, "log", "-n", "15", "--format=%H %cI %s"])
      pure (parseHistory exitCode out)

-- | The git log output as trimmed 'Text' on success with non-empty output; a
-- failing exit (not a repository, an empty repo with no commits) is 'Nothing' so
-- the caller renders an explicit placeholder rather than a blank anchor.
parseHistory :: ExitCode -> LazyChar8.ByteString -> Maybe Text
parseHistory exitCode out =
  let decoded = Text.stripEnd (decodeUtf8Lenient (LazyChar8.toStrict out))
  in if isSuccess exitCode && not (Text.null decoded)
       then Just decoded
       else Nothing

-- | The repo root of the first edited file, or Nothing when there are no files.
repoForFiles :: [FilePath] -> IO (Maybe FilePath)
repoForFiles [] = pure Nothing
repoForFiles (firstFile : _) = gitRoot (takeDirectory firstFile)

-- | The repo root of the first edited file, falling back to the current
-- directory's repo when the turn made no file edits.
repoForFilesOrCwd :: [FilePath] -> IO (Maybe FilePath)
repoForFilesOrCwd files = do
  fromFiles <- repoForFiles files
  case fromFiles of
    Just root -> pure (Just root)
    Nothing -> gitRoot "."
