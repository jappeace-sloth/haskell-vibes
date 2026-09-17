-- | OpenCode's non-interactive reviewer protocol. Only a completed final answer
-- counts as a verdict; tool output, earlier commentary, and errors do not.
module Claude.Gate.OpenCodeReviewer
  ( openCodeArgs
  , openCodeConfig
  , openCodeAnswer
  ) where

import Control.Monad (foldM)
import Data.Aeson (Object, Value (Object, String), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)

-- | Arguments for a fresh reviewer, inheriting a compatible reasoning variant.
openCodeArgs :: Text -> [(String, String)] -> [String]
openCodeArgs model environment =
  ["run", "--format", "json", "--agent", "vibes-gate-reviewer", "--model", Text.unpack model]
    <> inheritedVariant model environment

-- Variants belong to a model. Do not pass the worker's variant to an explicitly
-- different canary/critic model, which may not support that reasoning setting.
inheritedVariant :: Text -> [(String, String)] -> [String]
inheritedVariant model environment =
  if lookup "OPENCODE_GATE_MODEL" environment == Just (Text.unpack model)
    then case lookup "OPENCODE_GATE_VARIANT" environment of
      Nothing -> []
      Just "" -> []
      Just variant -> ["--variant", variant]
    else []

-- Decision: use a fresh primary agent in a fresh `opencode run` session. This
-- retains the existing OpenCode authentication, provider setup, and tools, unlike
-- a separate API client. Restrict the canary/rules agent to reading; the critic
-- can run tests. Disable delegation so a configured subagent cannot select Claude.
-- | Merge the review agent into existing inline JSON without dropping providers.
openCodeConfig :: Text -> Bool -> Maybe String -> Either String String
openCodeConfig model readOnly existing = do
  configuration <- case existing of
    Nothing -> Right KeyMap.empty
    Just encoded -> eitherDecodeStrict (encodeUtf8 (Text.pack encoded)) >>= parseEither (withObject "OpenCode config" pure)
  agents <- case KeyMap.lookup "agent" configuration of
    Nothing -> Right KeyMap.empty
    Just value -> parseEither (withObject "OpenCode agents" pure) value
  let configuredAgents = KeyMap.insert "vibes-gate-reviewer" (reviewAgent readOnly) agents
      configuredReview = KeyMap.insert "small_model" (String model)
        (KeyMap.insert "agent" (Object configuredAgents) configuration)
  pure (Text.unpack (decodeUtf8 (LazyByteString.toStrict (encode (Object configuredReview)))))

reviewAgent :: Bool -> Value
reviewAgent readOnly = object
  [ "mode" .= ("primary" :: Text)
  , "description" .= ("Independent stop-gate reviewer" :: Text)
  , "prompt" .= ("Review the supplied dossier independently. Follow its requested verdict format. Do not implement fixes, create branches, commit, push, or open pull requests. Report findings to the worker." :: Text)
  , "permission" .= object
      [ "*" .= (if readOnly then "deny" else "allow" :: Text)
      , "read" .= ("allow" :: Text)
      , "grep" .= ("allow" :: Text)
      , "glob" .= ("allow" :: Text)
      , "external_directory" .= ("allow" :: Text)
      , "task" .= ("deny" :: Text)
      , "question" .= ("deny" :: Text)
      ]
  ]

data ReviewEvent
  = StepStarted
  | AnswerText Text
  | StepFinished Text
  | ReviewFailed Text
  | ToolOutput
  | ReasoningOutput

data ReviewAnswer = ReviewAnswer
  { answerText :: Text
  , finishReason :: Maybe Text
  }

-- | Extract the last completed step's text, rejecting errors and partial output.
openCodeAnswer :: Text -> Either Text Text
openCodeAnswer output = do
  events <- traverse decodeEvent (filter (not . Text.null . Text.strip) (Text.lines output))
  answer <- foldM collectAnswer (ReviewAnswer "" Nothing) events
  if finishReason answer /= Just "stop" || Text.null (Text.strip (answerText answer))
    then Left "OpenCode reviewer returned no completed final answer. Check its model/login with opencode run --model <provider/model> before retrying the gate."
    else Right (answerText answer)

decodeEvent :: Text -> Either Text ReviewEvent
decodeEvent line = case eitherDecodeStrict (encodeUtf8 line) >>= parseEither parseEvent of
  Left reason -> Left ("Cannot decode OpenCode reviewer output: " <> Text.pack reason <> ". Check the installed OpenCode version and its --format json output.")
  Right event -> Right event

parseEvent :: Value -> Parser ReviewEvent
parseEvent = withObject "OpenCode run event" parseEventObject

parseEventObject :: Object -> Parser ReviewEvent
parseEventObject event = do
  eventType <- event .: "type"
  case (eventType :: Text) of
    "step_start" -> pure StepStarted
    "text" -> AnswerText <$> (event .: "part" >>= (.: "text"))
    "step_finish" -> StepFinished <$> (event .: "part" >>= (.: "reason"))
    "error" -> ReviewFailed . decodeUtf8 . LazyByteString.toStrict . encode <$> (event .: "error" :: Parser Value)
    "tool_use" -> pure ToolOutput
    "reasoning" -> pure ReasoningOutput
    unknown -> fail ("Unexpected OpenCode review event " <> Text.unpack unknown)

collectAnswer :: ReviewAnswer -> ReviewEvent -> Either Text ReviewAnswer
collectAnswer answer event = case event of
  StepStarted -> Right (ReviewAnswer "" Nothing)
  AnswerText text -> Right answer { answerText = answerText answer <> text }
  StepFinished reason -> Right answer { finishReason = Just reason }
  ReviewFailed reason -> Left ("OpenCode reviewer failed: " <> reason <> ". Check the selected model and use opencode auth login for authentication failures.")
  ToolOutput -> Right answer
  ReasoningOutput -> Right answer
