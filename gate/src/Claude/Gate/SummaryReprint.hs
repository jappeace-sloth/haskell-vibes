-- | The closing summary reprint.
--
-- Every reviewer block makes the worker answer the reviewer after it already
-- wrote its summary, so by the time the gate clears that summary sits above the
-- review exchange and may be stale. Once every phase has passed, the gate blocks
-- once more to have the worker reprint it, updated, as the turn's last message.
--
-- Decision: one closing block, not a "then reprint your summary" line on every
-- block reason. Per-block instructions yield a summary per round that a later
-- phase can bury again; only the closing block is guaranteed to land last.
module Claude.Gate.SummaryReprint
  ( blockWithFindings
  , requestSummaryReprint
  , summaryReprintReason
  ) where

import Control.Monad (when)
import Data.Text (Text)
import Claude.Gate.HookProtocol (BlockReason (BlockReason), blockAndExit)
import Claude.Gate.TurnState (TurnPaths (summaryOwed), flagExists, removeIfExists, writeFlag)

-- | Block the Stop with reviewer feedback for the worker, recording that the
-- worker owes the user a fresh summary once the gate clears. Infrastructure
-- failures and the working-hours warning block through 'blockAndExit' directly:
-- they are notices, not review feedback, so they owe no reprint.
blockWithFindings :: TurnPaths -> BlockReason -> IO a
blockWithFindings paths reason = do
  writeFlag (summaryOwed paths)
  blockAndExit reason

-- | Run once every phase has passed this Stop: if a reviewer blocked since the
-- last reprint, consume the debt and block to ask for the summary. The reprint
-- Stop finds every phase done or its stack empty, so it spawns no reviewer and
-- only a new reviewer block can owe another reprint.
requestSummaryReprint :: TurnPaths -> IO ()
requestSummaryReprint paths = do
  owed <- flagExists (summaryOwed paths)
  when owed $ do
    removeIfExists (summaryOwed paths)
    blockAndExit (BlockReason summaryReprintReason)

summaryReprintReason :: Text
summaryReprintReason =
  "The stop-gate is clear, but its reviewers gave you feedback this turn, so \
  \your summary for the user now sits above the whole review exchange and may \
  \be out of date. Reprint your final summary (or answer) for the user as your \
  \last message, updated with anything the review changed: fixes made, claims \
  \corrected, findings you rebutted. The user should not have to scroll back \
  \through the review rounds. Start no new work; this only asks for the summary."
