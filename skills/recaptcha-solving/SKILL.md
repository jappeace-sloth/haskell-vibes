---
name: recaptcha-solving
description: Solve reCAPTCHA v2 image challenges using Playwright MCP screenshot-based visual identification. Use when a web form has a reCAPTCHA "I'm not a robot" checkbox that triggers an image grid challenge.
---

# Solving reCAPTCHA v2 Image Challenges

Solve reCAPTCHA v2 ("I'm not a robot" checkbox -> image grid challenge) using
Playwright MCP tools. Works by taking a screenshot of the challenge grid,
visually identifying target objects, clicking matching squares, and verifying.

## Procedure

### 1. Click the checkbox

Find the reCAPTCHA iframe in the page snapshot. It contains a checkbox labeled
"I'm not a robot". Click it. This triggers the image challenge.

### 2. Take a screenshot immediately

A challenge dialog appears with an image grid (usually 4x4 or 3x3) and an
instruction like "Select all squares with motorcycles".

**Take a screenshot of the CAPTCHA dialog element** — this gives you the visual
content needed to identify which squares contain the target object.

### 3. Identify and click target squares

From the screenshot, identify which grid squares contain the requested object.
Click them in rapid succession. Do NOT deliberate too long.

### 4. Click Verify

After selecting all matching squares, click the "Verify" button immediately.

## CAPTCHA Types

### Single-round grid (best case)
- One static image grid, select all matching squares, click Verify, done
- Solvable in ~30-40 seconds
- This is the goal — fast identification, fast clicking, fast verify

### Multi-round "select and wait" (harder)
- After selecting squares, new tiles fade in to replace them
- Must keep selecting until no more targets appear
- 2-minute timeout makes this risky due to tool call latency
- **Strategy**: Click "Get a new challenge" button to hopefully get a simpler
  single-round grid instead of grinding through multiple rounds

## Speed Budget

The CAPTCHA has a **~2 minute expiry window**. Each Playwright tool call takes
several seconds. Budget:

- ~5s: click checkbox
- ~5s: take screenshot
- ~15s: identify targets from screenshot
- ~15s: click all target squares (rapid succession)
- ~5s: click Verify
- **Total: ~45 seconds**, leaving ~75 seconds buffer

**Do NOT over-analyze** — act on your best visual assessment. Getting 80% of
squares right is usually enough. Missing one edge case square is better than
timing out.

## Common Target Objects

motorcycles, bicycles, crosswalks, traffic lights, buses, fire hydrants,
stairs, chimneys, bridges, boats, palm trees, taxis, parking meters

## Failure Protocol: Hypothesize Before Retrying

**You can usually identify the correct squares — the bottleneck is speed.**
Do NOT just retry blindly. After each failed attempt, stop and think before
touching the CAPTCHA again.

### After each failure, write notes (to a file, not just in your head):

1. **What happened**: timeout? wrong squares? multi-round tiles kept appearing?
   CAPTCHA expired before you could click Verify?
2. **Why it failed**: Were you too slow taking the screenshot? Too slow clicking?
   Did you deliberate too long identifying squares? Did a multi-round challenge
   eat your time budget?
3. **Hypothesis**: What specific thing would fix it? e.g. "I spent 20s analyzing
   the screenshot — next time click immediately on obvious squares first, then
   re-examine", or "multi-round: hit Get New Challenge instead of grinding"
4. **Solution plan**: Write out the exact sequence of actions you will take,
   including which tool calls, before you start the next attempt

### Only retry ONCE you have a concrete plan

The CAPTCHA timer starts the moment you click the checkbox. Your plan must be
ready BEFORE you click. Think of it like:
- **Planning phase** (no timer): analyze what went wrong, devise strategy
- **Execution phase** (2-min timer): execute the plan as fast as possible

### Track all attempts

Keep a running log in a notes file:
```
## Attempt N
- Time: HH:MM:SS UTC
- Challenge type: [single-round 4x4 / multi-round 3x3 / etc]
- Target: [motorcycles / crosswalks / etc]
- Result: [success / fail]
- Failure reason: [timeout / wrong squares / etc]
- Hypothesis: [what to change]
- Plan for next attempt: [specific actions]
```

This prevents going in circles. If the same failure mode repeats 3 times,
escalate to a fundamentally different approach (audio challenge, new challenge,
or abort and report to user).

## Multi-Round Strategy

Multi-round challenges (tiles regenerate after selection) are the hardest because
each round costs ~15-20 seconds of tool calls. Strategies:

1. **First choice**: Click "Get a new challenge" (refresh button) — may get a
   simpler single-round grid
2. **If stuck in multi-round**: After selecting tiles, take a new screenshot
   immediately to see regenerated tiles. Have your clicking plan ready before
   the screenshot even loads.
3. **After 2 failed multi-round attempts**: Try "Get an audio challenge" instead.
   Audio challenges play a spoken number sequence — type what you hear.
4. **After 3 total failures**: Stop and report to user what's happening
