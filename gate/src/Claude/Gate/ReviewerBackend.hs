-- | Select the review harness and its model names without mixing providers.
module Claude.Gate.ReviewerBackend
  ( ReviewerBackend (ClaudeCode, OpenCode)
  , ReviewPhase (ComplexityCanary, AdversarialCritic, RuleReviewer)
  , reviewerBackend
  , backendExecutable
  , reviewModel
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Claude.Gate.GateConfig (envStr)
import System.Environment (lookupEnv)

-- | The CLI and authentication context used by an independent reviewer.
data ReviewerBackend = ClaudeCode | OpenCode

-- | The phase whose model override is being resolved.
data ReviewPhase = ComplexityCanary | AdversarialCritic | RuleReviewer

-- | Read the explicit backend, defaulting to Claude Code for its existing hooks.
reviewerBackend :: IO ReviewerBackend
reviewerBackend = do
  configured <- lookupEnv "CLAUDE_GATE_BACKEND"
  case configured of
    Nothing -> pure ClaudeCode
    Just "claude" -> pure ClaudeCode
    Just "opencode" -> pure OpenCode
    Just backend -> ioError (userError ("Unknown gate reviewer backend: " <> backend <> ". Set CLAUDE_GATE_BACKEND to claude or opencode."))

-- | Executable resolved through the gate process's PATH.
backendExecutable :: ReviewerBackend -> String
backendExecutable ClaudeCode = "claude"
backendExecutable OpenCode = "opencode"

-- Decision: inherit the OpenCode worker's provider/model rather than hard-code
-- a GPT SKU or translate Claude model names. Available GPT models vary by login;
-- per-phase OpenCode overrides allow a cheaper canary without affecting Claude.
-- | Select the backend-specific phase override or the worker model.
reviewModel :: ReviewPhase -> IO Text
reviewModel phase = do
  backend <- reviewerBackend
  case backend of
    ClaudeCode -> case phase of
      ComplexityCanary -> envStr "CLAUDE_DUMBIFY_MODEL" "claude-haiku-4-5"
      AdversarialCritic -> envStr "CLAUDE_CRITIQUE_MODEL" "claude-opus-4-8"
      RuleReviewer -> envStr "CLAUDE_REVIEWER_MODEL" "claude-sonnet-5"
    OpenCode -> do
      inherited <- envStr "OPENCODE_GATE_MODEL" ""
      model <- envStr (openCodeModelVariable phase) inherited
      if Text.null (Text.strip model) || not ("/" `Text.isInfixOf` model)
        then ioError (userError "OpenCode reviewer has no provider/model. Restart with the updated stopgate plugin or set OPENCODE_GATE_MODEL to an available openai/model-id.")
        else pure model

openCodeModelVariable :: ReviewPhase -> String
openCodeModelVariable ComplexityCanary = "OPENCODE_DUMBIFY_MODEL"
openCodeModelVariable AdversarialCritic = "OPENCODE_CRITIQUE_MODEL"
openCodeModelVariable RuleReviewer = "OPENCODE_REVIEWER_MODEL"
