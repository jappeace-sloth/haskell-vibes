-- | Extract the assistant's claims this turn from the session transcript.
--
-- The transcript is JSON Lines. A real user message is @type == "user"@ with a
-- /string/ content; a tool reply is also @type == "user"@ but with an /array/
-- content, which is how the two are told apart. The critique phase refutes the
-- prose the assistant produced since the most recent real user message, so we
-- collect the text blocks of every assistant entry after that point.
module Claude.Gate.Transcript
  ( TranscriptLine(..)
  , classifyLine
  , turnAssistantText
  ) where

import Data.Aeson (Value (Array, Object, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (doesFileExist)

-- | One transcript entry, reduced to what the critique cares about: a real user
-- prompt (the boundary), an assistant turn with its text blocks, or neither.
data TranscriptLine
  = RealUserPrompt
  | AssistantText [Text]
  | OtherLine
  deriving stock (Eq, Show)

-- | Classify a decoded transcript entry. Anything that is not a string-content
-- user message or an assistant message is OtherLine; that is the genuine meaning
-- of "an entry we do not care about", not a swallowed parse error (malformed
-- JSON never reaches here, see 'readLines').
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
-- content is a tool result, which does not count as a turn boundary.
userLine :: Maybe Value -> TranscriptLine
userLine = \case
  Just (String _userText) -> RealUserPrompt
  Just (Object _) -> OtherLine
  Just (Array _) -> OtherLine
  Just (Aeson.Number _) -> OtherLine
  Just (Aeson.Bool _) -> OtherLine
  Just Aeson.Null -> OtherLine
  Nothing -> OtherLine

-- | An assistant entry contributes its text blocks. Array content is the list of
-- content blocks (we keep the @text@ ones); a bare string content is itself the
-- text.
assistantLine :: Maybe Value -> TranscriptLine
assistantLine = \case
  Just (Array items) -> AssistantText (collectTextBlocks (toList items))
  Just (String text) -> AssistantText [text]
  Just (Object _) -> OtherLine
  Just (Aeson.Number _) -> OtherLine
  Just (Aeson.Bool _) -> OtherLine
  Just Aeson.Null -> OtherLine
  Nothing -> OtherLine

messageContent :: Value -> Maybe Value
messageContent value = lookupKey "message" value >>= lookupKey "content"

collectTextBlocks :: [Value] -> [Text]
collectTextBlocks items =
  [ text
  | item <- items
  , lookupKey "type" item == Just (String "text")
  , Just (String text) <- [lookupKey "text" item]
  ]

lookupKey :: Text -> Value -> Maybe Value
lookupKey key value = case value of
  Object fields -> KeyMap.lookup (Key.fromText key) fields
  Array _ -> Nothing
  String _ -> Nothing
  Aeson.Number _ -> Nothing
  Aeson.Bool _ -> Nothing
  Aeson.Null -> Nothing

-- | The assistant's text since the most recent real user message, joined with
-- newlines. This is the prose the critic refutes. A missing transcript is empty.
turnAssistantText :: FilePath -> IO Text
turnAssistantText path = do
  present <- doesFileExist path
  if not present
    then pure ""
    else do
      transcriptLines <- readLines path
      pure (Text.intercalate "\n" (concatMap assistantTextsOf (linesAfterLastUserPrompt transcriptLines)))

assistantTextsOf :: TranscriptLine -> [Text]
assistantTextsOf = \case
  RealUserPrompt -> []
  AssistantText texts -> texts
  OtherLine -> []

-- | The suffix of lines following the last real user prompt. Implemented by
-- reversing, taking lines up to the first prompt from the end, then reversing
-- back: 'takeWhile' from the end stops at the most recent prompt, so what
-- survives is exactly the lines after it (or all lines if there is no prompt).
linesAfterLastUserPrompt :: [TranscriptLine] -> [TranscriptLine]
linesAfterLastUserPrompt = reverse . takeWhile (not . isRealUserPrompt) . reverse

isRealUserPrompt :: TranscriptLine -> Bool
isRealUserPrompt = \case
  RealUserPrompt -> True
  AssistantText _ -> False
  OtherLine -> False

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
