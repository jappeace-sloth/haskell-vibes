# Useful code comments without the essays

Research date: 30 September 2026.

## Recommendation

A useful code comment gives its intended reader information needed to use,
understand, or safely change the code that the reader would otherwise have to
reconstruct. Keep that information accurate, close to its subject, and expressed
with no unnecessary repetition. This definition synthesizes Google's review
guidance, its C++ guide, and the comment-quality model of Steidl and
colleagues.[^review][^cpp][^study]

For Claude, adopt an information-value check and a brevity checkpoint: ordinary
implementation comments should normally be one or two sentences. A longer comment
must earn its space with a concrete contract, invariant, constraint, or explanation
of non-obvious behaviour. Remove redundant prose before removing useful knowledge.
The proposed wording appears below; the sentence budget is a local policy choice,
not a scientifically established limit.

## Scope and evidence

This report concerns comments in source code, including declaration documentation
such as Haddock, docstrings, and Javadoc. PR review comments and chat replies are
outside its scope. External design documents matter only when deciding where an
explanation belongs.

This is a targeted review of primary project guidance, an author's published
argument, and one empirical study, rather than a systematic literature review.
Sources were selected for explicit guidance on comment content, length, placement,
and maintenance, including evidence against simply banning long comments. All
linked sources were read on the research date. Recommendations below are a
synthesis; the sources' own prescriptions and the study's findings are identified
separately. None of these sources establishes how often Claude over-comments or
tests whether the proposed instruction changes its behaviour.

## What the sources agree on, and where they differ

| Source | Relevant finding or prescription | Implication for our rule |
|---|---|---|
| Google code-review guidance | Ask whether comments are necessary. Usually explain why; allow explanations of complex algorithms and regular expressions. Distinguish implementation comments from interface documentation.[^review] | Reject narration, but allow useful descriptions of behaviour. |
| Google C++ guide | Document contracts, lifetime rules, synchronization assumptions, and tricky implementation choices. Avoid obvious statements and duplicated declaration/definition documentation.[^cpp] | Comment information missing from names and types, in the appropriate place. |
| Linux kernel coding style | Warns against over-commenting and boilerplate that repeats signatures. Prefers function-head descriptions of what and possibly why, and strongly discourages explanations of how.[^linux] | A terse style has precedent, but its absolute wording is a project convention. |
| Python PEP 8 | Obvious inline comments distract; contradictory comments are worse than none. Update comments when code changes.[^pep8] | Accuracy and added meaning matter even for a one-line comment. |
| John Ousterhout | Comments can express information code cannot and let callers use an interface without reading its implementation.[^ousterhout] | Making all comments disappear is an unsuitable objective. |
| GHC coding style | Uses named Notes for substantial explanations, with short references from code. Notes describe the present state and preserve design reasoning.[^ghc] | Long explanations can remain useful without repeatedly interrupting code. |
| Steidl, Hummel, and Juergens | Separates comment categories and evaluates usefulness and coherence. In its sample, developers often retained longer comments containing non-local information.[^study] | Length and comment-to-code ratios are insufficient quality measures. |

The apparent disagreement over “what” and “how” mostly becomes manageable once the
reader's task is explicit. A caller needs what an operation promises. A maintainer
needs why an unusual implementation exists and sometimes how an irreducibly tricky
algorithm works. Neither needs each obvious statement translated into English.
Google makes these distinctions explicitly; the kernel's stronger ban on “how”
should not be generalized into a universal rule.[^review][^cpp][^linux]

## What deserves a comment?

### Information that changes a reader's understanding

Useful subjects include:

- A reason for choosing an approach over a plausible alternative, including an
  external compatibility constraint.[^review][^cpp]
- A contract not apparent from the signature: ownership, lifetime, mutation,
  special return values, or performance implications of use.[^cpp]
- An invariant or synchronization requirement a maintainer must preserve.[^cpp]
- An explanation or small example of genuinely difficult behaviour. Google names
  complex algorithms and regular expressions; GHC encourages concrete examples
  and references to relevant tests and tickets.[^review][^ghc]
- A temporary workaround with a traceable issue and a concrete removal condition,
  rather than an unqualified “TODO: improve this”.[^cpp]

Write for a competent contributor familiar with the language, who may not know
the project-specific constraint. Google's guide explicitly uses the next
contributor as its audience and distinguishes non-obvious behaviour from things
already clear to a reader who knows C++.[^cpp]

For Haskell, our application of this principle is to document semantics that the
type leaves open. A signature returning a list does not, by itself, promise order
or duplicate handling. Explain such promises when callers need them. Conversely,
repeating a type signature in prose adds little. This follows the distinction
between interface contracts and redundant descriptions.[^cpp][^ousterhout]

### Information better expressed in code

Try a clearer name, type, or structure when the comment merely decodes an obscure
identifier or explains an obvious sequence of operations. Google's C++ guide
specifically suggests named constants, enums instead of boolean arguments, and
named intermediate expressions before resorting to argument comments.[^cpp]

That is a preference, not an instruction to refactor every comment away.
Ousterhout argues that an interface comment can communicate more than a cumbersome
method name and save the reader from inspecting the body.[^ousterhout] Our rule
should ask whether a code change genuinely clarifies the program, rather than
rewarding a lower comment count.

### Information with an ongoing maintenance obligation

A correct comment today needs to stay correct after a code change. PEP 8 makes
updating comments an explicit priority.[^pep8] Review touched comments with the
code, including restrictions that a proposed change may invalidate.[^review]

Describe the current constraint and consequence. GHC distinguishes a comment that
describes a state from a commit message that describes a change. It allows
historical material when clearly signposted and relevant, and specifically
preserves design reasoning that prevents later mistakes.[^ghc] For Claude, the
application is to keep enduring rationale while removing the debugging diary,
the conversation with the user, and recaps of what the agent just changed.

## How short should comments be?

The reviewed sources do not establish an optimal universal word or line count.
In particular, the available empirical evidence here does not justify “long
comments are bad”.

Steidl, Hummel, and Juergens surveyed 16 developers, all with at least five years
of programming experience. Their length evaluation used 30 Java implementation
comments: ten with at most two words, ten with three to 29 words, and ten with at
least 30 words. Developers favoured keeping all ten long examples; nine received
at least 88% agreement. The authors report removal, directly or by method
extraction, for seven of the ten shortest examples. The middle group yielded no
clear preference.[^study]

These are judgements about different existing comments, not a controlled comparison
of short and verbose versions of the same explanation. The sample is small,
Java-based, and excludes jMol from the length evaluation after manual inspection
found poor comment quality there. It does not establish that adding words improves
comments, that all short comments are bad, or that the findings transfer directly
to AI-generated comments or Haskell. The authors themselves explicitly reject a
rule requiring at least 30 words.[^study]

Their useful distinction is between information recoverable from nearby code and
broader information the comment contributes. They also warn that many long inline
comments can indicate missing external architecture or domain documentation.
Comment volume alone cannot tell us whether the explanation is useful or correctly
placed.[^study]

Our proposed default is therefore one or two sentences for an ordinary
implementation comment, with a review checkpoint above three prose lines at the
file's normal wrapping width. These numbers are deliberately a local restraint on
verbosity. Passing the checkpoint means checking what would be lost by shortening,
not adding a sentence defending the comment's length. Splitting the same essay
into adjacent short comments does not satisfy the intent.

## Placement can solve the length problem

Put caller-facing documentation at the declaration, and implementation rationale
next to the relevant implementation. Avoid maintaining the same explanation in
both places.[^cpp]

For substantial reasoning shared by several functions, GHC offers a particularly
relevant Haskell precedent: a named `Note [Topic]` with precise references from
the affected code. The name makes the explanation findable and reusable without
copying it. GHC also recommends examples and specific ticket references.[^ghc]

Our recommendation is to retain a short local statement of the important constraint
and point to one named Note or version-controlled design document for the longer
argument. A proof or delicate invariant may belong in the source; a system-wide
design discussion may belong in `docs/`. Choose by who needs the information and
where it can be maintained together, rather than moving prose solely to pass a
line-count check.[^cpp][^ghc][^study]

## Examples for the proposed rule

These are illustrative examples written for this report, not quotations or claims
about behaviour in this repository. Their factual premises must be verified before
using them in real code.

### Delete narration

```haskell
-- Check whether there are any pending jobs.
if null pendingJobs then stopWorker else runJobs pendingJobs
```

The comment adds nothing to the names and expression. Delete it; do not replace
it with a shorter synonym. This applies the anti-redundancy guidance.[^cpp][^pep8]

### Shorten an explanation without losing its reason

```haskell
-- It is important that we preserve the order of the events here. The
-- order is the order in which the events were received from the provider.
-- Multiple events can have identical timestamps, so using timestamps
-- to sort them would not establish which event happened first. This
-- could cause the replay to produce a different state, which is why
-- we retain the original order rather than sorting the events.
```

The same constraint and consequence fit in:

```haskell
-- Preserve provider order: equal timestamps cannot determine replay order.
```

The revised comment keeps the reason instead of narrating the implementation.
This is the report's editing judgement, applying Google's rationale guidance and
GHC's preference for specific explanations.[^review][^ghc]

### Keep a contract that a type does not express

```haskell
-- | Preserve first-occurrence order; duplicate IDs keep the first event.
deduplicateEvents :: [Event] -> [Event]
```

This describes what callers can rely on without inspecting the implementation.
“Only comment why” would incorrectly reject it.[^cpp][^ousterhout]

### Preserve a significant decision concisely

```haskell
-- Decision: Use a FIFO rather than a priority queue because jobs must
-- execute in arrival order.
```

This records the choice, alternative, and decisive constraint required by the
existing [Decision Log rule](../CLAUDE.md#decision-log). A longer argument can live
in one named Note if it is needed; repeating the whole design discussion at every
queue operation adds no value.[^cpp][^ghc]

## Proposed CLAUDE.md wording

This is a proposal for a subsequent rule change. It applies to comments written
or modified during a task, including declaration documentation. The brevity
checkpoint applies specifically to ordinary implementation comments.

```markdown
# Code comments
- Every comment must add information the intended reader needs: a reason,
  contract, invariant, constraint, or explanation of non-obvious behaviour.
  Delete narration of obvious code and repetition of names or types.
- Prefer clearer names, types, or structure when they remove the need for an
  explanation. Do not refactor merely to eliminate a useful comment.
- Ordinary implementation comments should normally be one or two sentences.
  Above three prose lines at normal wrapping width, stop and try to shorten.
  Keep extra detail only when removing it loses necessary information; do not
  split the same explanation into smaller comments to evade this check.
- Preserve needed API documentation, examples, proofs, and subtle invariants.
  Put substantial shared reasoning in one named Note or design document, with
  a short local constraint and precise reference. Retain required legal and
  tool-directive comments.
- Describe the current code and verify factual claims. Update affected comments
  with code changes. Keep task recaps and debugging diaries out of source.
- Before finishing, review added and changed comments: remove every sentence
  whose deletion loses no useful information. Keep significant Decision:
  comments to the choice, relevant alternatives, and decisive reason.
```

This makes the requested stop measure a mandatory editing checkpoint. A future
automated reviewer should identify the redundant claim and suggest a deletion or
shorter wording, rather than fail a comment solely for crossing the threshold.
That implementation recommendation follows the evidence limitations above; it
has not been tested as an agent intervention.

The proposal complements the existing instruction to document confusing functions
at their declarations and retains the Decision Log requirement. When integrating
it, cross-reference these rules so the agent does not read them as competing
demands for extra prose. Required legal text and tool directives are excluded from
the editorial deletion test because they serve obligations beyond explanation;
the study likewise distinguishes copyright comments from explanatory ones.[^study]

Success should be assessed on reviewed changes: fewer redundant sentences, while
retaining contracts and rationale needed for correct use and maintenance. Raw
comment count is unsuitable as the target. This is a proposed evaluation criterion,
grounded in the study's distinction between quantity and quality, not a claim that
the rule's effectiveness has already been demonstrated.[^study]

## Sources

[^review]: Google, [“What to look for in a code review”, Comments section](https://google.github.io/eng-practices/review/reviewer/looking-for.html#comments). Primary organizational guidance. Covers necessity, rationale, exceptions for complex behaviour, and the distinction between comments and interface documentation.

[^cpp]: Google, [C++ Style Guide, Comments](https://google.github.io/styleguide/cppguide.html#Comments), especially Function Comments, Variable Comments, Implementation Comments, and TODO Comments. Primary project-style guidance. Supports contracts, invariants, placement, avoiding repetition, clearer code, and specific TODO removal conditions; its C++ conventions are not universal requirements.

[^linux]: Linux kernel documentation, [“Linux kernel coding style”, section 8, Commenting](https://www.kernel.org/doc/html/latest/process/coding-style.html#commenting). Primary project guidance. Explicitly cautions against over-commenting and signature-repeating kernel-doc boilerplate.

[^pep8]: Guido van Rossum, Barry Warsaw, and Alyssa Coghlan, [PEP 8, Comments and Inline Comments](https://peps.python.org/pep-0008/#comments). Created 2001, maintained guidance. Supports accuracy, updating comments, and the distinction between distracting narration and useful intent.

[^ousterhout]: John Ousterhout, *A Philosophy of Software Design*, second edition (2021), section 12.6, “A different opinion: comments are failures”, printed pp. 99–100, available in the [author-provided extract](https://web.stanford.edu/~ouster/cgi-bin/aposd2ndEdExtract.pdf#page=15) (PDF pp. 15–16; [publication context](https://web.stanford.edu/~ouster/cgi-bin/book.php)). Primary expert argument, not an experiment. Explains the information comments provide and why interface comments can avoid implementation reading.

[^ghc]: GHC developers, [Coding Style, section 2, Using Notes](https://gitlab.haskell.org/ghc/ghc/-/wikis/commentary/coding-style#2-using-notes), particularly sections 2.1–2.4. Primary Haskell project guidance. Covers named explanations, precise references, examples, and current-state descriptions versus change history.

[^study]: Daniela Steidl, Benjamin Hummel, and Elmar Juergens, [“Quality Analysis of Source Code Comments”](https://www.cqse.eu/fileadmin/content/news/publications/2013-quality-analysis-of-source-code-comments.pdf) (2013), author-hosted paper. Section V (PDF p. 4) defines coherence, usefulness, completeness, and consistency. Sections VI-B and VII (pp. 5–8) describe the length hypotheses, sampling, 16-person survey, and results. Sections VIII–IX (pp. 8–10) discuss placement, quantity metrics, case studies, and the limits of semi-automatic assessment. The survey measures developer judgements, not comprehension speed or defect reduction.
