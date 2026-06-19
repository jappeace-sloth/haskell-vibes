-- | Render recorded edits as labelled diff blocks for the reviewer prompt.
--
-- Showing the diff (the old and new text) rather than the whole file keeps the
-- prompt small and points the reviewer at exactly the text the agent wrote.
-- The reviewer is told to only flag text in a "with"/"new content" section.
module Gate.DiffRender
  ( renderDiffs
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Gate.Edit (Edit (..), Replacement (..))

-- | Render a turn's edits as one labelled block per edit, in order.
renderDiffs :: [Edit] -> Text
renderDiffs = Text.concat . map renderOne

renderOne :: Edit -> Text
renderOne edit =
  Text.concat
    [ "=== FILE: ", Text.pack (editPath edit), " (via ", toolLabel edit, ") ===\n"
    , editBody edit
    , "\n"
    ]

editPath :: Edit -> FilePath
editPath = \case
  SingleEdit path _ -> path
  MultiEditFile path _ -> path
  WriteFileContent path _ -> path
  NotebookCellSource path _ -> path

toolLabel :: Edit -> Text
toolLabel = \case
  SingleEdit _ _ -> "Edit"
  MultiEditFile _ _ -> "MultiEdit"
  WriteFileContent _ _ -> "Write"
  NotebookCellSource _ _ -> "NotebookEdit"

editBody :: Edit -> Text
editBody = \case
  SingleEdit _ replacement -> renderReplacement replacement
  MultiEditFile _ replacements -> Text.intercalate "\n" (map renderReplacement replacements)
  WriteFileContent _ content -> "--- new content ---\n" <> content
  NotebookCellSource _ source -> "--- new source ---\n" <> source

renderReplacement :: Replacement -> Text
renderReplacement (Replacement old new) =
  Text.concat ["--- replaced ---\n", old, "\n--- with ---\n", new]
