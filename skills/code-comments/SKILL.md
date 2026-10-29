---
name: code-comments
description: Rules for writing and reviewing code comments in any language, including declaration documentation (Haddock, docstrings, Javadoc). Load before writing or editing a comment, when deciding whether a comment is needed at all, and when reviewing a diff for comment quality. Also use for `Decision:` and `Note [Topic]` comments.
---

# Code comments

We assume the reader can read code. A comment is for what the code cannot
say on its own: why it is the way it is, what it promises, and where it is
odd. Everything else is noise that goes stale.

## Never describe the implementation

A comment that says what the code does is banned. "Loop over the orders and
sum the totals", "increment the retry counter", "call the handler with the
parsed body": the reader sees that by reading the next line, and when the
line changes the comment lies.

The one exception is an odd implementation: code that a competent reader
would pause at and ask "why on earth is it done like this?". Then the
comment answers that question. It explains why the obvious way does not
work, not what the odd way does.

```haskell
-- Bad: narrates the code.
-- Sort the list and take the first element.
smallest = head (sort xs)

-- Bad: still narration, just longer.
-- We fold over the map, inserting each key into the accumulator set.

-- Good: the implementation looks wrong and the comment says why it is not.
-- Insertion order must survive serialisation; Data.Map would resort the keys.
-- Fine: no comment at all for code that reads as it is.
```

Test for an existing or planned comment: delete it and reread the code. If
nothing a reader needs is lost, keep it deleted. If the reader now has to
reconstruct a reason, a constraint or a surprise, keep the comment and make
sure it states that reason rather than paraphrasing the code.

## What a comment is for

- Context: the design reasoning, the constraint that forced this shape, the
  alternative that was rejected and the decisive reason. Significant choices
  carry a `Decision:` prefix (see below).
- Contracts: preconditions, invariants, units, ownership and lifetime,
  synchronisation assumptions, what a caller may rely on. Declaration
  documentation describes what an operation promises to its caller, never how
  it achieves that.
- Weirdness: workarounds for a library bug, an ordering that matters for a
  non-obvious reason, a performance hack, an off-by-one that is intentional.
  Name the thing being worked around so a later reader can check whether it
  still applies.
- History that prevents a mistake: a failed approach and why it failed, a
  debugging finding that explains a constraint. The fuller change narrative
  belongs in the commit message; comment length limits do not apply there.

Prefer clearer names, types, or structure when they remove the need for an
explanation. Do not refactor merely to eliminate a useful comment.

## Form

- Ordinary implementation comments are one or two sentences. Above three
  prose lines at normal wrapping width, stop and shorten. Keep extra detail
  only when removing it loses necessary information; do not split one
  explanation into smaller comments to evade the check.
- No section banners: a ruled line, a title, another ruled line
  (`-- ------` / `-- The plan` / `-- ------`). To separate code, split it into
  modules named after what they contain. Haddock `-- *` headings in an export
  list are API documentation and stay.
- Use GHC-style `Note [Topic]` comments for substantial explanations of
  design, invariants, and interactions. Explain the higher-level idea with
  examples or counterexamples, not a paraphrase of the code. Reference it
  from code sites with a short `See Note [Topic]`; the full explanation lives
  in one place.
- `Decision:` comments record what was chosen, which alternatives were
  considered, and why. Use the file's own comment syntax (`-- Decision:` in
  Haskell, `# Decision:` in Nix/shell/YAML, `// Decision:` in C-likes) so
  `grep -rn 'Decision:'` finds them. Never write decisions to memory; memory
  is per-instance and not in version control.
- Preserve needed API documentation, examples, proofs, and subtle invariants.
  Retain required legal text and tool directives (pragmas, linter
  directives); those serve obligations beyond explanation.
- Keep comments accurate as code changes. A stale comment is worse than none.

## Before finishing a task

Review every added or changed comment:

1. Does it describe what the code does? Delete it, unless the code is odd and
   the comment explains why. Then rewrite it so it states the reason.
2. Does any sentence repeat a name, a type, or the next line of code? Remove
   that sentence.
3. Is a `Decision:` comment down to the choice, the relevant alternatives,
   and the decisive reason?
4. Would the comment survive the next refactor of the lines beneath it? If it
   is pinned to the current shape of the code, that is a sign it narrates
   rather than explains.

When invoked directly on a diff, apply this checklist to every comment in the
diff and fix what fails it.

## Background

The rules synthesise Google's review and C++ guidance, the Linux kernel
style, PEP 8, Ousterhout, GHC's Notes convention and the Steidl, Hummel and
Juergens comment-quality study. See [research.md](research.md) for the
sources, what they agree on and where this skill takes a stricter line than
they do.
