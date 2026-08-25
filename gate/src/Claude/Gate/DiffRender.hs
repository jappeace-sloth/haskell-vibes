-- | Render recorded edits as labelled diff blocks for the reviewer prompt.
--
-- Showing the diff (the old and new text) rather than the whole file keeps the
-- prompt small and points the reviewer at exactly the text the agent wrote.
-- The reviewer is told to only flag text in a "with"/"new content" section.
--
-- Decision: edits superseded by a later full-content write of the same file
-- are dropped before rendering, and the block opens with a note that the full
-- file is the authoritative final state. Long turns (mid-turn user steering)
-- produce several rewrites of one file; showing every stale snapshot made
-- reviewers report "the diffs contradict the full file" as a blocking finding
-- against code that was fine. The alternative, rendering a real
-- turn-start-to-now diff per file, was rejected: record runs on PostToolUse,
-- so no pre-edit baseline exists to diff against, and shell-made edits bypass
-- recording entirely either way.
module Claude.Gate.DiffRender
  ( renderDiffs
  , collapseSupersededEdits
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Claude.Gate.Edit (Edit (..), Replacement (..), editFilePath)

-- | Render a turn's edits as one labelled block per edit, in order, after
-- dropping superseded snapshots. Empty input renders empty (no note).
renderDiffs :: [Edit] -> Text
renderDiffs edits = case collapseSupersededEdits edits of
  [] -> ""
  collapsed -> supersedeNote <> Text.concat (map renderOne collapsed)

-- | Shown once above the diff blocks. The agent may also edit files through
-- shell commands the hooks never see, so reviewers must treat the full file
-- as final rather than expect the diffs to reconstruct it.
supersedeNote :: Text
supersedeNote =
  "NOTE: edits are listed in the order they were applied; for files that were\n\
  \rewritten during the turn, earlier superseded snapshots are omitted. Where a\n\
  \diff and the full current file contents disagree (e.g. the agent also edited\n\
  \files via shell commands, which are not recorded here), the full file is the\n\
  \authoritative final state; do not report such a difference as a finding.\n\n"

-- | Drop every edit that a later full-content write of the same file makes
-- irrelevant: only the last 'WriteFileContent' / 'NotebookCellSource' of a
-- file and the incremental edits after it describe the state a reviewer sees.
-- Edits to other files are untouched and the overall order is preserved.
collapseSupersededEdits :: [Edit] -> [Edit]
collapseSupersededEdits edits =
  map snd (filter (editStillCurrent (zip [0 ..] edits)) (zip [0 ..] edits))

editStillCurrent :: [(Int, Edit)] -> (Int, Edit) -> Bool
editStillCurrent allEdits (index, edit) =
  index >= lastFullContentIndex allEdits (editFilePath edit)

-- | The index of the last full-content edit of the given file, or 0 when the
-- file only ever received incremental edits (index 0 never drops anything).
lastFullContentIndex :: [(Int, Edit)] -> FilePath -> Int
lastFullContentIndex allEdits path =
  foldl' max 0 (map fst (filter (isFullContentFor path) allEdits))

isFullContentFor :: FilePath -> (Int, Edit) -> Bool
isFullContentFor path (_, edit) =
  editFilePath edit == path && isFullContent edit

isFullContent :: Edit -> Bool
isFullContent edit = case edit of
  WriteFileContent _ _ -> True
  NotebookCellSource _ _ -> True
  SingleEdit _ _ -> False
  MultiEditFile _ _ -> False

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
