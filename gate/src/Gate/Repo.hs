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
  ) where

import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory)
import System.Process.Typed (proc, readProcess)

-- | The git work-tree root containing a directory, or Nothing if it is not in a
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
