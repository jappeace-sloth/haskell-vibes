-- | A single file mutation recorded during a turn.
--
-- The PostToolUse hook only fires for the four edit tools (the matcher in
-- settings.json is @Write|Edit|MultiEdit|NotebookEdit@), so those four
-- constructors are the complete set: there is no "unknown tool" case to fall
-- back on. Each edit is persisted as one JSON line on the review stack and read
-- back at Stop time to reconstruct the diff for the reviewer.
module Gate.Edit
  ( Edit(..)
  , Replacement(..)
  , editFilePath
  , parseEditFromTool
  ) where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value, object, withObject, (.:), (.=))
import Data.Aeson.Types qualified as Aeson (Parser, parseEither)
import Data.Text (Text)

-- | One old/new text pair, as carried by Edit and each element of MultiEdit.
data Replacement = Replacement
  { replacedText :: Text
  , replacementText :: Text
  }

instance FromJSON Replacement where
  parseJSON :: Value -> Aeson.Parser Replacement
  parseJSON = withObject "Replacement" $ \object' ->
    Replacement
      <$> object' .: "old_string"
      <*> object' .: "new_string"

-- | A recorded edit, one constructor per edit tool the hook fires for.
data Edit
  = SingleEdit FilePath Replacement
  | MultiEditFile FilePath [Replacement]
  | WriteFileContent FilePath Text
  | NotebookCellSource FilePath Text

editFilePath :: Edit -> FilePath
editFilePath = \case
  SingleEdit path _ -> path
  MultiEditFile path _ -> path
  WriteFileContent path _ -> path
  NotebookCellSource path _ -> path

-- | Parse an edit from a PostToolUse payload's tool name and tool_input. The
-- tool name selects the shape; an unexpected name means the settings.json
-- matcher and this code disagree, which is a bug we surface loudly rather than
-- silently drop.
parseEditFromTool :: Text -> Value -> Either String Edit
parseEditFromTool tool = Aeson.parseEither (editParser tool)

editParser :: Text -> Value -> Aeson.Parser Edit
editParser tool = withObject "tool_input" $ \object' -> case tool of
  "Edit" ->
    SingleEdit <$> object' .: "file_path" <*> (Replacement <$> object' .: "old_string" <*> object' .: "new_string")
  "MultiEdit" ->
    MultiEditFile <$> object' .: "file_path" <*> object' .: "edits"
  "Write" ->
    WriteFileContent <$> object' .: "file_path" <*> object' .: "content"
  "NotebookEdit" ->
    NotebookCellSource <$> object' .: "file_path" <*> object' .: "new_source"
  other ->
    fail ("unexpected edit tool: " <> show other)

-- Persisted form: tag with the tool name and keep exactly the fields needed to
-- reconstruct the diff. Round-trips through parseEditFromTool's shape so the
-- record and review halves of the gate stay in sync.
instance ToJSON Edit where
  toJSON :: Edit -> Value
  toJSON = \case
    SingleEdit path (Replacement old new) ->
      object ["tool" .= ("Edit" :: Text), "file_path" .= path, "old_string" .= old, "new_string" .= new]
    MultiEditFile path edits ->
      object ["tool" .= ("MultiEdit" :: Text), "file_path" .= path, "edits" .= map replacementToJSON edits]
    WriteFileContent path content ->
      object ["tool" .= ("Write" :: Text), "file_path" .= path, "content" .= content]
    NotebookCellSource path source ->
      object ["tool" .= ("NotebookEdit" :: Text), "file_path" .= path, "new_source" .= source]

replacementToJSON :: Replacement -> Value
replacementToJSON (Replacement old new) =
  object ["old_string" .= old, "new_string" .= new]

instance FromJSON Edit where
  parseJSON :: Value -> Aeson.Parser Edit
  parseJSON value = flip (withObject "Edit") value $ \object' -> do
    tool <- object' .: "tool"
    editParser tool value
