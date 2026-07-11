-- | The JSON protocol Claude Code uses to talk to hook commands.
--
-- A hook reads one JSON object from stdin describing the event, and a Stop hook
-- may write one JSON object to stdout to influence the turn. This module models
-- the fields the gate reads from the input, and the two output shapes it emits:
-- a @decision: block@ (with a reason fed back to the main-loop model) and a
-- @systemMessage@ (shown to the user, not added to model context).
module Claude.Gate.HookProtocol
  ( HookEvent(..)
  , BlockReason(..)
  , readHookEvent
  , emitBlock
  , blockAndExit
  , blockAndExitWithNotice
  , emitSystemMessage
  ) where

import Data.Aeson (FromJSON (parseJSON), Value, object, withObject, (.!=), (.:?), (.=))
import Data.Aeson qualified as Aeson
-- Data.Aeson does not re-export Parser; it lives in Data.Aeson.Types. Both are
-- qualified as Aeson so the FromJSON method signature reads Aeson.Parser.
import Data.Aeson.Types qualified as Aeson (Parser)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import System.Exit (exitSuccess)

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
    Left err -> error ("claude-gate: could not decode hook event from stdin: " <> err)
    Right event -> pure event

-- | Block the Stop and feed the reason back to the model. Printing this JSON and
-- exiting 0 is how a Stop hook asks the turn to continue.
emitBlock :: BlockReason -> IO ()
emitBlock (BlockReason reason) =
  LazyByteString.putStr (Aeson.encode (object ["decision" .= ("block" :: Text), "reason" .= reason]))

-- | A blocking phase emits its reason and ends the gate immediately: later
-- phases do not run on a Stop that one phase already blocked.
blockAndExit :: BlockReason -> IO a
blockAndExit reason = emitBlock reason >> exitSuccess

-- | Block the Stop and, in the SAME hook response, show the user a notice. A
-- Stop hook may emit only one JSON object, so the model-facing block reason and
-- the user-facing systemMessage are combined into one object: the model gets the
-- reason it must act on, and the human watching sees the notice rather than being
-- left to guess at a phase that broke silently. Used for infrastructure failures
-- (a nested reviewer that timed out or returned a weird exit status).
--
-- Decision: emit one JSON object carrying both "reason" and "systemMessage",
-- rather than reusing emitBlock then emitSystemMessage as two writes. Alternative
-- considered: two separate emits. Rejected because a hook may write only one JSON
-- object to stdout, so the second write is ignored or breaks parsing; a single
-- merged object is the only way to deliver both signals from one hook response.
blockAndExitWithNotice :: BlockReason -> Text -> IO a
blockAndExitWithNotice (BlockReason reason) notice = do
  LazyByteString.putStr
    (Aeson.encode (object ["decision" .= ("block" :: Text), "reason" .= reason, "systemMessage" .= notice]))
  exitSuccess

-- | Emit a user-visible, non-blocking message (the end-of-gate "gate clear"
-- notice). systemMessage is shown to the user and is not added to model context.
emitSystemMessage :: Text -> IO ()
emitSystemMessage message =
  LazyByteString.putStr (Aeson.encode (object ["systemMessage" .= message]))
