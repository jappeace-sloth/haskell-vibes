-- | Decide whether a turn did anything worth verifying, by reading the session
-- transcript.
--
-- The transcript is JSON Lines. A real user message is @type == "user"@ with a
-- /string/ content; a tool reply is also @type == "user"@ but with an /array/
-- content, which is how the two are told apart. We look at every assistant
-- tool call made since the most recent real user message and report whether any
-- of them touched state (edited files, ran a command, fetched the web, or
-- called an MCP tool). That is the signal the Stop gate uses to ask for
-- verification.
module Gate.Transcript
  ( TranscriptLine(..)
  , classifyLine
  , toolsSinceLastUserPrompt
  , isStateTouching
  , turnTouchedState
  ) where

import Data.Aeson (Value (Array, Object, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.Foldable (toList)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (doesFileExist)

-- | One transcript entry, reduced to what the gate cares about: was it a real
-- user prompt, an assistant turn that called tools, or neither.
data TranscriptLine
  = RealUserPrompt
  | AssistantToolUses [Text]
  | OtherLine
  deriving stock (Eq, Show)

-- | Classify a decoded transcript entry. Anything that is not a string-content
-- user message or an array-content assistant message is OtherLine; that is the
-- genuine meaning of "an entry we do not care about", not a swallowed parse
-- error (malformed JSON never reaches here, see 'readLines').
classifyLine :: Value -> TranscriptLine
classifyLine value = case lookupKey "type" value of
  Just (String "user") -> userLine (messageContent value)
  Just (String "assistant") -> assistantLine (messageContent value)
  -- Any other "type" string is an entry we ignore. String values cannot be
  -- enumerated, so this is the one unavoidable catch-all.
  Just (String _otherType) -> OtherLine
  Just (Object _) -> OtherLine
  Just (Array _) -> OtherLine
  Just (Aeson.Number _) -> OtherLine
  Just (Aeson.Bool _) -> OtherLine
  Just Aeson.Null -> OtherLine
  Nothing -> OtherLine

-- | A user entry is a real prompt only when its content is a string; an array
-- content is a tool result, which does not count.
userLine :: Maybe Value -> TranscriptLine
userLine = \case
  Just (String _userText) -> RealUserPrompt
  Just (Object _) -> OtherLine
  Just (Array _) -> OtherLine
  Just (Aeson.Number _) -> OtherLine
  Just (Aeson.Bool _) -> OtherLine
  Just Aeson.Null -> OtherLine
  Nothing -> OtherLine

-- | An assistant entry contributes its tool-use names when its content is the
-- array of content blocks; any other content shape contributes nothing.
assistantLine :: Maybe Value -> TranscriptLine
assistantLine = \case
  Just (Array items) -> AssistantToolUses (collectToolUseNames (toList items))
  Just (String _) -> OtherLine
  Just (Object _) -> OtherLine
  Just (Aeson.Number _) -> OtherLine
  Just (Aeson.Bool _) -> OtherLine
  Just Aeson.Null -> OtherLine
  Nothing -> OtherLine

messageContent :: Value -> Maybe Value
messageContent value = lookupKey "message" value >>= lookupKey "content"

collectToolUseNames :: [Value] -> [Text]
collectToolUseNames items =
  [ name
  | item <- items
  , lookupKey "type" item == Just (String "tool_use")
  , Just (String name) <- [lookupKey "name" item]
  ]

lookupKey :: Text -> Value -> Maybe Value
lookupKey key value = case value of
  Object fields -> KeyMap.lookup (Key.fromText key) fields
  Array _ -> Nothing
  String _ -> Nothing
  Aeson.Number _ -> Nothing
  Aeson.Bool _ -> Nothing
  Aeson.Null -> Nothing

-- | The deduplicated tool names called after the most recent real user prompt.
-- If there is no real user prompt in the transcript, all lines count, matching
-- the shell hook's default of scanning from the start.
toolsSinceLastUserPrompt :: [TranscriptLine] -> [Text]
toolsSinceLastUserPrompt = nub . concatMap toolNamesOf . linesAfterLastUserPrompt

-- | The suffix of lines following the last real user prompt. Implemented by
-- reversing, taking lines up to the first prompt from the end, then reversing
-- back: 'takeWhile' from the end stops at the most recent prompt, so what
-- survives is exactly the lines after it (or all lines if there is no prompt).
linesAfterLastUserPrompt :: [TranscriptLine] -> [TranscriptLine]
linesAfterLastUserPrompt = reverse . takeWhile (not . isRealUserPrompt) . reverse

isRealUserPrompt :: TranscriptLine -> Bool
isRealUserPrompt = \case
  RealUserPrompt -> True
  AssistantToolUses _ -> False
  OtherLine -> False

toolNamesOf :: TranscriptLine -> [Text]
toolNamesOf = \case
  RealUserPrompt -> []
  AssistantToolUses names -> names
  OtherLine -> []

-- | Whether a tool call counts as touching state worth reporting on. State
-- mutators and research tools both qualify; every MCP tool (@mcp__*@) is
-- side-effecting or research-style, so it qualifies too.
isStateTouching :: Text -> Bool
isStateTouching name =
  name `elem` stateTouchingTools || "mcp__" `Text.isPrefixOf` name

stateTouchingTools :: [Text]
stateTouchingTools =
  ["Write", "Edit", "MultiEdit", "NotebookEdit", "Bash", "WebFetch", "WebSearch"]

-- | Read the transcript file and report whether the current turn touched state.
-- A missing transcript means nothing to verify.
turnTouchedState :: FilePath -> IO Bool
turnTouchedState path = do
  present <- doesFileExist path
  if present
    then do
      transcriptLines <- readLines path
      pure (any isStateTouching (toolsSinceLastUserPrompt transcriptLines))
    else pure False

-- | Parse the transcript file into classified lines. Blank lines and lines that
-- are not valid JSON classify as OtherLine; the transcript is appended to live
-- and the tail can be a partial write, so a single unparseable line is expected
-- noise, not a failure of the whole turn.
readLines :: FilePath -> IO [TranscriptLine]
readLines path = do
  contents <- ByteString.readFile path
  pure (map classifyRaw (ByteString.lines contents))

classifyRaw :: ByteString.ByteString -> TranscriptLine
classifyRaw raw = maybe OtherLine classifyLine (Aeson.decodeStrict raw)
