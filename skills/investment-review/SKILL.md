---
name: investment-review
description: Review and document investment portfolio positions from Interactive Brokers statements. Use when the user wants to review stocks, document investment theses, set exit strategies, or analyze portfolio positions. Also trigger when discussing IB statements, stock positions, or investment decisions.
argument-hint: [ib-statement-path]
user-invocable: false
---

# Investment Portfolio Review

You are helping the user review and document their investment portfolio.
The investment report lives at: `/home/claude/vibes/jappie-software/strategy/investments.org`

## Workflow

### 1. Parse the IB Statement

If an Interactive Brokers HTML statement path is provided via `$ARGUMENTS[0]`,
or one exists in `/home/claude/vibes/ib/`, parse it to extract open positions:
- Symbol, quantity, cost price, cost basis, close price, current value, unrealized P/L
- Group by currency (AUD, EUR, JPY, USD, etc.)

### 2. For Each Position

Go through positions one at a time with the user:

1. **Identify the company** — look up ticker if needed via web search
2. **Ask the user for their thesis** — why did they buy it?
   - If they don't remember, research the company and present what it does to jog their memory
3. **Document the thesis** in the investments.org report
4. **Set exit strategies** with both downside and upside:

#### Downside (cut losses / thesis invalidation):
- Set concrete internal company targets with deadlines
- Give the company reasonable slack beyond their own stated targets
- Example: "If X hasn't happened by [date], sell everything"

#### Upside (take profits, tiered):
- Research the company's targets, market cap, and comparable valuations
- Calculate reasonable price targets based on projected fundamentals
- Propose a tiered profit-taking plan to derisk and rebalance
- Example: "Sell 50% at $X, sell remaining at $Y"

### 3. Flag Action Items

Maintain an Action Items section at the top of the report with:
- **SELL** — positions where the thesis is broken, with reasons
- **FURTHER ANALYSIS** — positions needing more research
- Resolved items marked as RESOLVED with outcome

### 4. Portfolio-Level Notes

Document the overall portfolio strategy (diversification thesis,
currency strategy, sector themes) at the top of the report.

## Report Format

Use org-mode (`.org`) format. Each position should have:

```org
*** TICKER — Company Name (Exchange)
- Acquired: YYYY-MM-DD (or "before May 2025" if unknown)
- Quantity: N
- Cost basis: CUR X (CUR Y/share)
- *Thesis:* Why the position was bought
- *Exit strategy:*
  Downside (cut losses):
  1. [Concrete milestone + deadline]. If not met, sell.
  Upside (take profits, tiered):
  1. Sell N shares at $X (rationale)
  2. Sell remaining N shares at $Y (rationale)
- *Notes:*
  [YYYY-MM-DD] Date-tagged observations, monitoring updates
```

### 5. Evaluating New Stock Candidates

When researching a potential new position, approach with skepticism.
Ask these questions in order — if any is a dealbreaker, stop early:

1. **Is it in the S&P 500?** If yes, it belongs in the retirement
   account (which holds a synthetic index), not the main IB account
   (U7722441). Flag it but don't reject — just note which account
   it should go into.

2. **Can we afford a meaningful position?** Check share price against
   available cash. At least 3+ shares preferred.

3. **What's the moat?** Prefer picks-and-shovels monopolies (like ASML,
   TSM) over commodity producers. If the company sells a commodity with
   no pricing power, it's probably a value trap regardless of P/E.

4. **Is the thesis already priced in?** Check:
   - P/E vs historical average (>50% premium = caution)
   - How much the stock has already run on this narrative
   - Whether the story is well-known (crowded trade)

5. **Deep due diligence — always read annual reports.** Never rely on
   narratives alone. For any attractive candidate, check:
   - Revenue and FCF history (5 years) — is it stable or wild?
   - Free cash flow, not just net income (net income includes non-cash
     accounting items; FCF shows real money in the bank)
   - Debt levels and how they're serviced
   - Where revenue actually comes from (segment breakdown)
   - Input costs — what are the company's major expenses? Are those
     costs stable or exposed to external shocks (e.g. oil prices for
     miners, gas prices for producers)?
   - Insider buying/selling
   - Recent earnings call commentary

6. **Geopolitical/macro cross-check.** Does the current macro situation
   (e.g. Strait of Hormuz blockade, sanctions, trade wars) help or
   hurt this specific company? Don't assume — verify. Example: the
   Hormuz blockade suppressed US Henry Hub gas prices while lifting
   international LNG prices — helping LNG exporters but hurting US
   gas producers.

7. **Document the decision.** Whether buying, watchlisting, or
   rejecting, record it in the strategy doc with reasoning so we
   don't re-investigate the same names.

### 6. Report Sections

The investments.org report maintains these sections:
- **Action Items** — current tasks (SELL, REDEPLOY, FURTHER ANALYSIS)
- **Positions by currency** — active holdings with thesis and exit strategy
- **Watchlist** — stocks we like but are too expensive right now,
  with buy triggers
- **Considered and Rejected** — stocks we investigated and passed on,
  with reasons

## Guidelines

- Approach all stock analysis with skepticism — always look for the
  bear case and why something might be cheap for good reason
- Be proactive about researching companies the user doesn't remember
- Present financials (revenue, market cap, FCF, EBITDA) when setting
  price targets. Prefer FCF over net income for companies with complex
  accounting (derivatives, mark-to-market, etc.)
- Use web search to look up company info, recent performance, and analyst outlook
- Always read annual reports and earnings calls for serious candidates
- When the user says a thesis is broken, add it to the SELL action items immediately
- For tiered profit-taking, calculate targets based on company fundamentals, not vibes
- Keep the conversation flowing naturally — go stock by stock, don't overwhelm
- Check input costs and supply chain dependencies — a company can have
  a great demand story but get killed by rising costs
- When a stock looks "cheap" (low P/E), always ask why — the market
  is usually right about commodity cyclicals
