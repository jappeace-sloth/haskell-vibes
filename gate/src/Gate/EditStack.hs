-- | Reading the per-turn edit stack the phases review.
--
-- record-edit appends one JSON-encoded edit per line. The phases read it back to
-- render diffs and to list the touched files; Phase A also returns a claimed
-- stack to the live stack when its reviewer fails, so the next Stop retries.
module Gate.EditStack
  ( readEdits
  , stackFilePaths
  , stackHasCode
  , returnClaimedToStack
  ) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Char8 qualified as ByteString
import Data.List (isSuffixOf, nub, sort)
import Gate.Edit (Edit, editFilePath)
import Gate.TurnState (TurnPaths (claimedStack, reviewStack), removeIfExists)
import System.Directory (doesFileExist)

-- | Read a stack file back into edits. We wrote these lines ourselves, so a line
-- that fails to decode is a bug in this program, surfaced loudly.
readEdits :: FilePath -> IO [Edit]
readEdits path = do
  contents <- ByteString.readFile path
  pure (map decodeEdit (filter (not . ByteString.null) (ByteString.lines contents)))

decodeEdit :: ByteString.ByteString -> Edit
decodeEdit raw = case Aeson.eitherDecodeStrict raw of
  Right edit -> edit
  Left err -> error ("vibes-gate: corrupt edit on the review stack: " <> err)

-- | The sorted, deduplicated file paths recorded on a stack file.
stackFilePaths :: FilePath -> IO [FilePath]
stackFilePaths path = do
  present <- doesFileExist path
  if not present
    then pure []
    else do
      edits <- readEdits path
      pure (sort (nub (map editFilePath edits)))

-- | Whether any file on the stack is source code. Dumbify is about code
-- comprehension, so prose and config edits do not trigger it.
stackHasCode :: FilePath -> IO Bool
stackHasCode path = do
  paths <- stackFilePaths path
  pure (any isCode paths)

isCode :: FilePath -> Bool
isCode path = any (`isSuffixOf` path) codeExtensions

codeExtensions :: [FilePath]
codeExtensions =
  [ ".hs", ".lhs", ".hsig", ".cabal", ".nix", ".sh", ".bash", ".py", ".rs"
  , ".js", ".ts", ".tsx", ".go", ".c", ".h", ".cpp", ".hpp", ".java"
  ]

-- | Return the claimed diffs to the live stack so the next Stop re-reviews them,
-- then drop the claimed copy. Used when the rule reviewer fails: the diffs must
-- not be lost to an infrastructure hiccup.
returnClaimedToStack :: TurnPaths -> IO ()
returnClaimedToStack paths = do
  present <- doesFileExist (claimedStack paths)
  if not present
    then pure ()
    else do
      claimed <- StrictByteString.readFile (claimedStack paths)
      StrictByteString.appendFile (reviewStack paths) claimed
      removeIfExists (claimedStack paths)
