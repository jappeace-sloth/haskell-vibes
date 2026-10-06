---
name: changelog
description: >
  Write, review or summarize changelogs. A changelog is not a commit history:
  each version gets a short summary a human can glance over, then one line per
  pull request linking it; the details live in version control. Use when
  adding a ChangeLog/CHANGELOG entry, bumping a version or preparing a release,
  reviewing a changelog in a PR, or when asked what changed in a dependency
  between two versions.
argument-hint: "[version or version range]"
---

# Changelogs

## Core principle

A changelog is not a commit history.  A reader opens it with one question:
should I upgrade, and what happens if I do?  Each version answers that in a
summary they can read in ten seconds.  Below it, one line per pull request
with a link lets them find more.  Everything else (how it was implemented,
benchmarks, the debugging story) belongs in the PR, the commit message or
the version control history.

## Shape of an entry

```markdown
## 2.1.1

New functions only; existing code is unaffected.  `Crypto.PubKey.ECDSA` gains
RFC 6979 deterministic nonces, `Crypto.Cipher.ChaCha.Poly1305` does a whole
ChaCha20-Poly1305 message in one call, and `Crypto.Cipher.AES.GCM` gains
`decryptWithTag` for protocols that carry the tag apart from the ciphertext.

* ECDSA nonces derived from the key and message (RFC 6979)
  [#219](https://github.com/OWNER/REPO/pull/219)
* A GCM decrypt that hands back the tag instead of comparing it
  [#220](https://github.com/OWNER/REPO/pull/220)
```

### The summary

It answers three questions, in this order:

1. Does upgrading break me?  Name the exact functions or types whose
   signature changed, the input that is now refused, the errors that now
   arrive differently, and what the caller has to do.  When nothing breaks,
   say so outright ("No API change", "New functions only; existing code is
   unaffected"): it is the most reassuring sentence in the file.
2. What do I gain?  Security fixes, speed, new features, described by their
   effect rather than their mechanism.  Give a number only when it is a
   headline ("up to nine times faster"), never a microbenchmark.
3. Do I have to act?  A broken or deprecated release, a new build
   requirement, "use 2.1.5 or later".

Length: one to three sentences for a patch release, a paragraph for a minor
one, and at most three short paragraphs (gains, breaks, deprecations) for a
large major release.  Anything longer is the commit history creeping back.

### The bullets

One line per pull request that shipped in the version, each linking its PR.
Phrase the line for a user, not as the raw commit subject when that subject
is jargon: "perf(gcm): read a short block where it lies" says nothing to a
reader, while "Faster AES-GCM on short messages" does.  CI-only and test-only
PRs can go at the end of the list.

### Avoid

- A bullet list with no summary above it: that is a commit log.
- Explaining the domain (what a side channel or a nonce is).  Say what was
  done and what it means for the reader.
- Implementation narrative: registers, loop unrolling, nanoseconds.
- Opening a paragraph with a bold label ("**Breaking changes.**").  Write
  "Upgrading can break code in three ways." instead.  The global prose rules
  apply as well (no mid-sentence em-dash).

## Verify before you write

Every sentence in a summary is a claim about shipped code, so check it
against the code, not against PR titles or memory.  Each of these checks
caught a real error in crypton's 2.x changelog (October 2026):

1. What shipped in a version comes from the tags.  Merge commits and squash
   merges both carry the PR number:

   ```bash
   git log --format=%s vOLD..vNEW | grep -oE '#[0-9]+' | sort -t'#' -k2 -un
   ```

   Crypton filed five PRs under 2.0.1 that shipped in 2.1.0, which made a
   signature change look like a break in a patch release.  The list is a
   candidate list: a number can be an issue a subject refers to
   (mysql-haskell's "Add Field typeclass ... (#86)" names issue #86), so
   confirm each with `gh pr view N`.  A PR closed on GitHub but landed as a
   direct commit has no number in the log; match it by subject.
2. "No API change" needs an API diff.  Crypton 2.0.0 said "No exported
   function changed its signature"; the diff found two, and two constructors
   added to `CryptoError` where the changelog named one.  For Haskell, diff
   what Haddock says the package exports with
   [scripts/hs-api-diff.py](scripts/hs-api-diff.py):

   ```bash
   # two releases, fetched from Hackage
   ~/.claude/skills/changelog/scripts/hs-api-diff.py crypton-2.0.0 crypton-2.1.7
   # the last release against the working tree
   cabal haddock --haddock-hoogle   # writes dist-newstyle/.../doc/html/PKG/PKG.txt
   ~/.claude/skills/changelog/scripts/hs-api-diff.py PKG-1.3.0 dist-newstyle/build/*/*/PKG-*/doc/html/PKG/PKG.txt
   ```

   Because it reads Haddock's output rather than the source, it sees
   re-exports, operators, modules without an export list, constructors,
   record fields, class methods and instances.  It reports REMOVED and
   CHANGED entities and ADDED CONSTRUCTOR on an existing type (breaks
   matches without a wildcard).  Instances are matched without module
   qualifiers, because docs from different GHC versions qualify classes
   differently; a removal still lowers the count and is reported.  Hackage
   has no docs for a release whose build failed (crypton 2.1.3 and 2.1.4),
   and the script stops with an error rather than reporting nothing.  Other
   ecosystems have their own tools (cargo-semver-checks, japicmp,
   api-extractor).  No API diff sees behaviour breaks such as input that is
   now refused; those come from reading the PRs.
3. Read the PR body for anything that touches security or breaks callers;
   titles undersell.  "reject missing and oversized authentication tags"
   turned out to mean a zero-length tag had skipped authentication entirely.
4. Read the whole range before concluding.  A mysql-haskell commit claimed
   crypton 2.0 broke only bcrypt and Poly1305 after reading a third of the
   section; the section lists 26 breaking changes.

## Writing the entry for our own release

1. Find the range: `git describe --tags --abbrev=0` gives the last release,
   then list the PRs with the command above.
2. Sort each PR into breaks, gains, must-act or internal.
3. Run the API diff against the last release tag.
4. Write the summary first, then the bullets.  Keep the file's existing
   heading convention (mysql-haskell uses `## 1.3.1 -- 2026.10.06`).
5. Reread it as a user: can they decide whether to upgrade from the summary
   alone?

Hackage renders the changelog from the uploaded tarball, so a fix on master
shows there only after the next release; list the file under
`extra-doc-files` so Hackage shows it at all.

## Summarizing someone else's changelog

When the user asks what changed in a dependency between two versions:

1. Fetch the changelog for the whole range and read all of it.  Check the
   repository's default branch too: the published copy can lag behind (on
   6 Oct 2026 crypton's master was already condensed while Hackage still
   showed the long version).
2. Answer in this order: a table of what we call against what changed, which
   is the real question; one row per version with its gist; the breaking
   changes in plain words.  Leave the implementation detail out.
3. Verify the conclusion against the code: grep our imports of the package,
   and run the API diff on the dependency's tags.

## In someone else's repository

Follow their format.  To propose this one, open a PR or issue whose
concrete value is the corrections a version check turns up, and offer the
smaller change as a fallback (summaries added above their existing list).
