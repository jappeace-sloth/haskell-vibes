-- | Render the current contents of the touched files for a reviewer prompt.
--
-- The dumbify canary and the rule reviewer both get the diffs AND the full
-- current file, so a reference the diff makes to code defined elsewhere in the
-- same file is not a false "I can't see it" confusion, and the reviewer can
-- judge the ABSENCE of required elements (e.g. a missing type signature) that a
-- diff fragment alone cannot show. Each file is capped to keep the prompt bounded.
module Gate.FileContext
  ( renderFullFiles
  , maxFileContextChars
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.ByteString qualified as ByteString
import System.Directory (doesFileExist)

-- | Each file's contents are truncated to this many bytes, matching the shell
-- gate's @head -c 40000@ per file.
maxFileContextChars :: Int
maxFileContextChars = 40_000

-- | A labelled block per existing file, in the given order. Missing files are
-- skipped (a path may have been deleted this turn).
renderFullFiles :: [FilePath] -> IO Text
renderFullFiles paths = Text.concat <$> mapM renderOne paths

renderOne :: FilePath -> IO Text
renderOne path = do
  present <- doesFileExist path
  if not present
    then pure ""
    else do
      raw <- ByteString.readFile path
      let body = decodeUtf8Lenient (ByteString.take maxFileContextChars raw)
      pure (Text.concat ["\n--- ", Text.pack path, " ---\n", body, "\n"])
