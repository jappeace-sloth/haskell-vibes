-- | The two prompts the Stop gate produces: the Phase A rule-review prompt sent
-- to a smaller reviewer model, and the Phase B verification nudge fed back to
-- the main-loop model. Also the parsing of the reviewer's reply.
--
-- Keeping the prompt text here, separate from the orchestration in
-- "Gate.StopGate", makes the wording easy to find and edit without wading
-- through control flow.
module Gate.ReviewPrompt
  ( reviewerModel
  , buildReviewPrompt
  , maxDiffPromptChars
  , hasViolations
  , reviewBlockReason
  , reviewerFailedReason
  , verifyReason
  ) where

import Data.Text (Text)
import Data.Text qualified as Text

-- | Phase A reviewer model. Decision: Sonnet rather than Haiku. The review only
-- fires on turns that edited files and batches that turn's diffs into one call,
-- so cost is per-edit-turn, not per-Stop, and the extra reasoning catches
-- semantic violations (silent failures, tests asserting static content) a
-- smaller model misses. The main-loop model is still the final judge.
reviewerModel :: Text
reviewerModel = "claude-sonnet-4-6"

-- | The rendered diffs are truncated to this many characters so a giant turn
-- cannot blow up the reviewer prompt. Matches the shell hook's @head -c 40000@.
maxDiffPromptChars :: Int
maxDiffPromptChars = 40_000

-- | Assemble the reviewer prompt from the rules corpus and the rendered diffs.
buildReviewPrompt :: Text -> Text -> Text
buildReviewPrompt corpus renderedDiffs =
  Text.concat
    [ reviewPromptHeader
    , corpus
    , "\n=== DIFFS JUST APPLIED ===\n"
    , Text.take maxDiffPromptChars renderedDiffs
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

-- | A reviewer reply reports violations when it is non-empty and contains at
-- least one line beginning with @VIOLATION:@. Empty output (a CLI failure or
-- network hiccup) is treated as clean so the gate never blocks on infra.
hasViolations :: Text -> Bool
hasViolations reviewOutput =
  not (Text.null (Text.strip reviewOutput))
    && any ("VIOLATION:" `Text.isPrefixOf`) (Text.lines reviewOutput)

-- | The block reason shown to the main-loop model when the reviewer flags
-- something. It frames the model as the final judge: fix or rebut, never
-- silently ignore.
reviewBlockReason :: Text -> Text
reviewBlockReason reviewOutput =
  Text.concat
    [ "A ", reviewerModel, " reviewer flagged possible rule violations in the diffs you just applied.\n"
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

-- | Shown to the main-loop model when the reviewer could not produce a verdict
-- (timeout, missing claude CLI, spawn error). Surfaced rather than silently
-- treated as a clean pass, so the turn is not trusted on an unchecked diff.
reviewerFailedReason :: Text -> Text
reviewerFailedReason detail =
  Text.concat
    [ "GATE INFRASTRUCTURE FAILURE: the ", reviewerModel, " rule reviewer could not run, so the "
    , "diffs you applied this turn were NOT rule-checked. This is surfaced rather than silently "
    , "passed off as clean. Find out why before trusting the turn (timeout, missing claude CLI, "
    , "auth, model error). Set CLAUDE_SKIP_RULE_CHECK=1 to disable.\n\n--- detail ---\n"
    , detail
    ]

-- | The Phase B verification nudge. This is the final prompt of the turn: review
-- has already passed by the time the gate emits it.
verifyReason :: Text
verifyReason =
  "Before ending this turn, verify your work through external observation, not introspection. \
  \You have tools. Use them. Saying \"it should work\" is not verification; demonstrating \"I ran X and observed Y\" is. \
  \Prefer the most authoritative evidence you can obtain. Evidence is not equal: \
  \a compiler or type-checker error, a failing test, a non-zero exit code, or a process the machine actually executed are extremely trustworthy, because the tool cannot misreport them. \
  \A document, comment, README or status note on disk is weak evidence: it states what someone intended, not what is true now, and much of it was written by an AI (jappeace-sloth) so it may be confidently wrong. \
  \If a more authoritative tool can settle the question, use it rather than citing a weaker source: run the type-checker, run the test, run the command and read its exit code, instead of quoting prose that claims the work is done. \
  \If you have already verified this way and reported it, end the turn. \
  \Otherwise verify now and report what you observed and how authoritative that observation is."
