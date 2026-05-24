---
name: dumbify-my-code
description: >
  Complexity canary: use haiku to verify code is understandable in isolation.
  Use as a standard review step after writing non-trivial code, after completing
  a feature, or when asked to "dumbify", "simplify for AI", or "review for
  complexity". Also trigger proactively when you've just written functions with
  6+ parameters, 40+ lines, or deep nesting.
argument-hint: [file-or-function]
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Agent
---

# Dumbify My Code

Make code understandable by smaller AI models (haiku-class) without changing
behaviour. The goal: a haiku-level model should be able to read any single
function and correctly explain what it does, what its inputs mean, and what
its outputs are.

## Why

Haiku is a complexity canary. If haiku can understand a function in isolation,
then any human or model can reason about it without loading surrounding code
into their head. If haiku struggles, the function needs too much context —
it's too complex for quick comprehension regardless of who's reading it.

Use this as a **standard review step** after writing non-trivial code, not
just for dedicated refactoring sessions. Be eager to run it.

## Process

### 1. Identify target functions

If `$ARGUMENTS` names a file or function, start there. Otherwise, scan the
codebase for functions that are likely to confuse a small model:

- Functions longer than 40 lines
- Functions with more than 6 parameters
- Where-blocks that capture variables from enclosing scope
- Deeply nested case/if trees (3+ levels)
- Functions named `go`, `loop`, `helper`, `aux`, `step`
- Large case dispatches mixing unrelated concerns

### 2. Send each function to haiku for explanation

For each candidate function, spawn a haiku agent with:
- The function's source code
- Enough context (type signatures of called functions, domain explanation)
- The prompt: "Explain what this function does, what its inputs and outputs
  are, and any concerns you have about understanding it. Be honest if
  anything confuses you."

Do NOT explain the code to haiku yourself — the point is to test whether the
code is self-explanatory with minimal context.

### 3. Evaluate haiku's understanding

For each response, check:
- **Correct understanding**: haiku accurately described inputs, outputs, logic
- **Wrong claims**: haiku stated something factually incorrect about the code
  (e.g. "parameter X is unused" when it's passed to a helper)
- **Confusion signals**: hedging language, questions, "I'm not sure", "I think"
- **Missed points**: important behaviour haiku didn't mention at all

### 4. Apply targeted fixes (no behaviour changes)

Based on what confused haiku, apply these patterns:

#### Split large case dispatches into per-branch functions
If a function dispatches on a sum type with branches longer than ~10 lines
each, extract each branch into a named function. The dispatch function
becomes a thin router.

**Before:**
```haskell
process entry = case entryType entry of
  TypeA -> do {- 30 lines -}
  TypeB -> do {- 40 lines -}
  TypeC -> do {- 25 lines -}
```

**After:**
```haskell
process entry = case entryType entry of
  TypeA -> processTypeA entry
  TypeB -> processTypeB entry
  TypeC -> processTypeC entry
```

#### Bundle threading parameters into records
If 4+ parameters are threaded unchanged through recursive calls, group them
into a named record. This reduces parameter count and makes the "what changes
per call" vs "what's constant" distinction visible.

**Before:**
```haskell
loop config http delay locale current total items acc = ...
  loop config http delay locale (current+1) total rest (r:acc)
```

**After:**
```haskell
data ImportEnv = ImportEnv
  { envConfig :: Config, envHttp :: HttpFn, envDelay :: Int, envLocale :: Text }

loop env current total items acc = ...
  loop env (current+1) total rest (r:acc)
```

#### Add domain-bridging doc comments
When a function's parameters use types from domain A but the function
operates in domain B, add a comment explaining the mapping.

```haskell
-- | Register translations for a Shopify collection.
-- A 'CategoryTranslation' maps to a collection translation because
-- MijnWebwinkel categories become Shopify collections during import.
registerOneCollectionLocale :: ... -> Entity CategoryTranslation -> IO ()
```

#### Make error-case defaults explicit
Replace `fromMaybe defaultValue (Map.lookup ...)` with a comment or a more
descriptive pattern when the default is suspicious (e.g. empty string, zero).

#### Extract where-blocks that shadow or capture
If a where-block captures 3+ variables from the enclosing scope, extract it
to a top-level function with explicit parameters. Use the module export list
to keep it private.

### 5. Verify with haiku again

After making changes, send the modified functions back to haiku. Confirm:
- Previous confusions are resolved
- No new confusions introduced
- Haiku can now correctly explain the function without hedging

### 6. Build and test

Run the project's build and test suite to confirm no behaviour changes.

## What NOT to do

- Do NOT change function behaviour or semantics
- Do NOT add error handling, logging, or validation that wasn't there before
- Do NOT refactor calling code unless necessary to accommodate a signature change
- Do NOT rename public API functions (internal helpers are fair game)
- Do NOT add type annotations to every let binding just for documentation — only where they clarify a non-obvious type
- Do NOT use this as an excuse for premature abstraction — only introduce records/helpers when haiku demonstrably struggled
