-- | The Phase A rule-review prompt and the parsing of the reviewer's reply.
--
-- Keeping the prompt text here, separate from the orchestration in
-- "Gate.RuleReview", makes the wording easy to find and edit without wading
-- through control flow.
module Gate.ReviewPrompt
  ( buildReviewPrompt
  , maxDiffPromptChars
  , hasViolations
  , reviewBlockReason
  ) where

import Data.Text (Text)
import Data.Text qualified as Text

-- | The rendered diffs are truncated to this many characters so a giant turn
-- cannot blow up the reviewer prompt. Matches the shell hook's @head -c 40000@.
maxDiffPromptChars :: Int
maxDiffPromptChars = 40_000

-- | Assemble the reviewer prompt from the rules corpus, the rendered diffs, and
-- the full current contents of the touched files (so the reviewer can judge the
-- absence of required elements that a diff fragment cannot show).
buildReviewPrompt :: Text -> Text -> Text -> Text
buildReviewPrompt corpus renderedDiffs fullFiles =
  Text.concat
    [ reviewPromptHeader
    , corpus
    , "\n=== DIFFS JUST APPLIED ===\n"
    , Text.take maxDiffPromptChars renderedDiffs
    , "\n=== FULL FILE CONTENTS (context; judge presence/absence of required elements only for definitions that appear in the diffs above) ===\n"
    , fullFiles
    ]

reviewPromptHeader :: Text
reviewPromptHeader =
  "You are a rule-compliance reviewer. Another Claude Code agent (a larger model\n\
  \than you) just finished a turn in which it made the edits shown below. You are\n\
  \reviewing the DIFFS of those edits, not whole files. Your output is fed back to\n\
  \that larger model, which then decides whether to fix the file or rebut your\n\
  \finding. Give it enough evidence to judge, not just a label.\n\
  \\n\
  \Below is a corpus of rules from CLAUDE.md and the relevant skills, followed by\n\
  \the diffs that were just applied.\n\
  \\n\
  \Be strict about what counts as a violation:\n\
  \\n\
  \- Only flag clear, objective violations of a rule stated in the rules corpus.\n\
  \  Quote the rule you are applying.\n\
  \- Only flag text that appears in a \"--- with ---\", \"--- new content ---\" or\n\
  \  \"--- new source ---\" section: that is what the agent actually wrote. Do not\n\
  \  flag text in a \"--- replaced ---\" section; that is the old text being removed.\n\
  \- A violation can also be the ABSENCE of required text. For rules of the form\n\
  \  \"always do X\" / \"every Y must have Z\" (e.g. \"always add a top-level type\n\
  \  signature to every top-level binding\"), a diff fragment cannot show a missing\n\
  \  line. So for any top-level definition that appears in the diffs (added or\n\
  \  modified this turn), consult the FULL FILE CONTENTS section below to check\n\
  \  whether the required element is present; if it is missing, flag it. Apply this\n\
  \  ONLY to definitions that appear in the diffs, never to untouched code.\n\
  \- Do NOT flag stylistic preferences that are not stated in the rules.\n\
  \- Do NOT flag judgement calls or things that \"might be better\".\n\
  \- If you are unsure, do not flag it.\n\
  \- Skill rules only apply when the skill's trigger conditions match the file\n\
  \  being reviewed.\n\
  \\n\
  \Response format:\n\
  \\n\
  \- If there are no violations: respond with the single line `OK`.\n\
  \- Otherwise: one block per violation, no markdown, with these labelled lines:\n\
  \\n\
  \    VIOLATION: <one-sentence summary>\n\
  \    RULE: \"<verbatim quote of the rule, including which file/skill it came from>\"\n\
  \    EVIDENCE: <file path>: <the offending text, copied verbatim from a newly\n\
  \              written section>\n\
  \    REASONING: <one or two sentences naming the concrete mechanism by which the\n\
  \               text breaks the rule. Note any borderline-ness so the larger\n\
  \               model can decide whether to fix or rebut.>\n\
  \\n\
  \Separate blocks with a blank line.\n\
  \\n\
  \=== RULES ===\n"

-- | A reviewer reply reports violations when it contains at least one line
-- beginning with @VIOLATION:@.
hasViolations :: Text -> Bool
hasViolations reviewOutput =
  any ("VIOLATION:" `Text.isPrefixOf`) (Text.lines reviewOutput)

-- | The block reason shown to the main-loop model when the reviewer flags
-- something. It frames the model as the final judge: fix or rebut, never
-- silently ignore.
reviewBlockReason :: Text -> Text -> Text
reviewBlockReason model reviewOutput =
  Text.concat
    [ "A ", model, " reviewer flagged possible rule violations in the diffs you just applied.\n"
    , "You are the larger model and the final judge. For each finding, either:\n"
    , "  1. Agree: edit the file to fix it (the fix is re-reviewed automatically), or\n"
    , "  2. Disagree: explain to the user why the finding is wrong (the reviewer misread\n"
    , "     the rule, the rule does not apply to this file type, evidence out of context)\n"
    , "     and proceed without fixing.\n"
    , "Do not silently ignore findings. Set CLAUDE_SKIP_RULE_CHECK=1 to disable.\n"
    , "\n--- reviewer findings ---\n"
    , reviewOutput
    , "\n--- end reviewer findings ---"
    ]
