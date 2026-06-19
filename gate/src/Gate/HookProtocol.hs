-- | The JSON protocol Claude Code uses to talk to hook commands.
--
-- A hook reads one JSON object from stdin describing the event, and a Stop or
-- PostToolUse hook may write one JSON object to stdout to influence the turn.
-- This module models just the fields the gate needs from the input, and the
-- single output shape it ever emits: a @decision: block@ with a reason that is
-- fed back to the main-loop model.
module Gate.HookProtocol
  ( HookEvent(..)
  , BlockReason(..)
  , readHookEvent
  , emitBlock
  ) where

import Data.Aeson (FromJSON (parseJSON), Value, object, withObject, (.!=), (.:?), (.=))
import Data.Aeson qualified as Aeson
-- Data.Aeson does not re-export Parser; it lives in Data.Aeson.Types. Both are
-- qualified as Aeson so the FromJSON method signature reads Aeson.Parser.
import Data.Aeson.Types qualified as Aeson (Parser)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)

-- | The subset of a hook's stdin payload the gate reads. Every field except
-- the session id is optional because which fields are present depends on the
-- event (PostToolUse carries a tool, Stop carries a transcript path).
data HookEvent = HookEvent
  { sessionId :: Text
  , transcriptPath :: Maybe FilePath
  , toolName :: Maybe Text
  , toolInput :: Maybe Value
  }

instance FromJSON HookEvent where
  parseJSON :: Value -> Aeson.Parser HookEvent
  parseJSON = withObject "HookEvent" $ \object' ->
    HookEvent
      <$> object' .:? "session_id" .!= "default"
      <*> object' .:? "transcript_path"
      <*> object' .:? "tool_name"
      <*> object' .:? "tool_input"

-- | The text shown back to the main-loop model when the gate blocks the Stop.
newtype BlockReason = BlockReason Text

-- | Read and decode the hook event from stdin. A malformed payload is a bug in
-- the harness contract, not something to paper over, so we crash loudly.
readHookEvent :: IO HookEvent
readHookEvent = do
  raw <- LazyByteString.getContents
  case Aeson.eitherDecode raw of
    Left err -> error ("vibes-gate: could not decode hook event from stdin: " <> err)
    Right event -> pure event

-- | Emit the one output shape the gate uses: block the Stop and feed the reason
-- back to the model. Printing this and exiting 0 is how a Stop hook asks the
-- turn to continue.
emitBlock :: BlockReason -> IO ()
emitBlock (BlockReason reason) =
  LazyByteString.putStr (Aeson.encode (object ["decision" .= ("block" :: Text), "reason" .= reason]))
