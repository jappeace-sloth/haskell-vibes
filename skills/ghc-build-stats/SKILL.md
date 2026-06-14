---
name: ghc-build-stats
description: >-
  Measure and shrink a Haskell/cabal project's build critical path with the
  ghc-build-stats GHC plugin + analyzer. Use when a build is slow, won't get
  faster with more cores, or you want to know which modules gate compilation
  and how to decouple them so more modules compile in parallel.
argument-hint: "[--cores N]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Analysing the build critical path with ghc-build-stats

A parallel build can never finish faster than its **critical path**: the
longest chain of modules where each waits for the previous to compile. Adding
cores past that point does nothing. `ghc-build-stats` measures it. The job is
to (1) get the number, then (2) shorten the chain so more modules compile in
parallel.

Two separate ceilings, don't confuse them:

- **Critical path**: the dependency-chain floor. Lower it by *decoupling
  modules*. This skill's main target.
- **Realised parallelism**: whether the build actually reaches that floor.
  `cabal -jN` does **not** parallelise modules within one library; GHC's own
  `-j` does, but scales badly under `-O2` due to GC contention. The cheap fix
  (no code change) is RTS-tuned parallel make (see the last section).

## What the tool is

- `ghc-build-stats-plugin`: a GHC driver plugin (`GHC.BuildStats.Plugin`).
  While GHC compiles, it writes one NDJSON line per module to
  `<dumpdir>/build-stats.ndjson`: `{"name", "start_time", "duration", "deps"}`,
  with `duration` measured *inside* GHC (more accurate than timing log lines).
- `ghc-build-stats`: an executable that reads that NDJSON and prints the
  10 slowest modules plus the weighted critical path, simulating `--cores N`.

Both are on Hackage and build with GHC 9.10/9.12/9.14. Source:
https://codeberg.org/teo/ghc-build-stats.

## One-time setup (per machine)

Run this skill's `scripts/setup.sh` from the project root. It:

1. `cabal get`s and builds the **analyzer** exe, copying it to
   `/tmp/ghc-build-stats`.
2. `cabal get`s the **plugin**, patches `WriteMode` -> `AppendMode` (see
   gotcha 1), and `cabal install --lib`s it into the cabal store so the
   `build-stats` flag can find it.

Do this inside the project's shell (`nix-shell shell.nix --run ...` here) so
the plugin builds against the same GHC the project uses.

## The cabal flag

Wire the plugin behind a manual cabal flag so the normal (nix) build never
needs the Hackage-only plugin. In your `<package>.cabal` (this is the shape
used in the jappeace/mijn-webwinkel-migraine library stanza):

```cabal
flag build-stats
  description: Instrument the library build with ghc-build-stats-plugin.
  default: False
  manual: True

library
  ...
  if flag(build-stats)
    build-depends: ghc-build-stats-plugin
    ghc-options: -fplugin=GHC.BuildStats.Plugin
```

To add this to another project, copy that `flag` stanza and `if flag(...)`
block. Keep `default: False` so cabal2nix / the default build don't require
the plugin.

## Collect stats + analyse

```sh
rm -f /tmp/build-stats.ndjson
nix-shell --max-jobs 1 shell.nix --run \
  "cabal clean; cabal build -j1 -fbuild-stats --disable-shared lib:<your-package> \
     --ghc-options='-dumpdir /tmp/'"
# the plugin wrote /tmp/build-stats.ndjson (the -dumpdir directory)
/tmp/ghc-build-stats --cores $(nproc) /tmp/build-stats.ndjson
```

`-j1` is deliberate: per-module durations are measured without contention, and
the analyzer *simulates* the chosen core count from the dependency graph, so a
serial build gives the cleanest input. (On a non-nix project drop the
`nix-shell` wrapper and the `--max-jobs 1`.)

### Why each non-obvious flag

1. **`--disable-shared` is required.** The plugin only emits on a single code
   path. With `-dynamic-too` (cabal's default, building `.o` + `.dyn_o`) its
   write is gated to the dynamic sub-pass, which doesn't fire under cabal
   `--make`, and you get an empty file. Building one way only removes the gate.
2. **The plugin must be patched to `AppendMode`** (setup.sh does this). Upstream
   v0.1.0.0 opens the file in `WriteMode`; cabal runs *separate* `ghc`
   processes for compiling and for linking, and the link process re-runs the
   driver plugin and truncates the file the compile pass wrote. AppendMode +
   deleting the file beforehand gives the full set with no duplicates.
3. **The flag is `-dumpdir DIR`**, not `-ddump-dir` (that makes GHC print its
   usage and abort). It sets where `build-stats.ndjson` lands.
4. **nix-pinned projects:** adding the plugin to `build-depends`
   *unconditionally* breaks `shell.nix` (cabal2nix can't provision a
   Hackage-only package). The `build-stats` flag defaulting to `False` keeps
   the default nix derivation clean; `cabal build -fbuild-stats` flips it at
   the cabal layer and resolves the plugin from the cabal store. Changing the
   `.cabal` re-runs cabal2nix, which needs `nix-shell --max-jobs 1`.

## Reading the output

```
Critical path, 13.22s total, composed of 10 modules:
1.57 s, ...ShopifyBackup
3.34 s, ...ShopifyImport
3.97 s, ...ShopifyImport.GraphQL
...
TOTAL: 31.65        <- serial sum of every module
```

- **Critical-path total** is the parallel-build floor. **TOTAL / critical
  path** is the maximum speedup any number of cores can buy. If that ratio is
  ~2, even a 64-core machine can only roughly halve the build.
- The listed chain *is* the thing to attack. Look for a fat module on it, then
  ask *why* it's on the path; often a downstream module depends on the whole
  module for a couple of cheap things while that module also pulls in heavy
  deps.

## Acting on it: decouple via leaf "Types" modules

The highest-leverage move is usually to pull the cheap things a hub depends on
out of a heavy module, so the hub stops waiting for it.

Pattern:
1. Find an edge `Hub -> Heavy` on the critical path where `Hub` imports only a
   few **plain types / pure helpers** from `Heavy`, but `Heavy` also imports
   something expensive (HTTP, HTML parsing, another heavy module).
2. Create `Heavy.Types` (or `Heavy.Core`) containing just those types/helpers,
   importing only the project's base types module (here `DomainTypes`).
3. Re-export them from `Heavy` so **no call site changes**.
4. Point `Hub` at `Heavy.Types`. Re-measure.

Worked example from jappeace/mijn-webwinkel-migraine (commit "Lift Database
off the scrape pipeline"):
`Database` imported four record types from `CustomerScrape` and
`FetchFailure` + `parseCategoryUrl` from `Crawler`. That dragged the whole
`Scrape -> Crawler -> CustomerScrape` chain onto the path to `Database` and
thus onto the entire Shopify export/import tail. Extracting
`CustomerScrape.Types` and `Crawler.Types` (both `DomainTypes`-only) cut the
critical path **16.91s -> 13.22s** with no behaviour change. Verify with
`cabal build` (`-Werror` clean) and `cabal test` before and after.

Things that do *not* help: splitting a module whose successor needs all of it
(e.g. `ShopifyImport` needs nearly all of `GraphQL`, so they stay serial unless
genuinely partitioned), or chasing modules that aren't on the printed path.

## The other lever: actually use the cores (no code change)

If the realised build is far above the critical-path floor, parallelism isn't
engaging. Measured here: `cabal -j16` ~37s (no module parallelism for a single
lib); `--ghc-options=-j16` ~32s (poor scaling); **`--ghc-options='-j16 +RTS
-A128m -qn8 -RTS'` ~23s** (the large allocation area and capped parallel GC fix
GHC parallel-make's GC contention). Put those flags in `ghc-options` or a
`cabal.project` for everyday builds; they need no source change and compose
with a shorter critical path.

## Cleanup

The instrumented build leaves `dist-newstyle` in a single-way, plugin-loaded
state. Before normal work: `cabal clean` (and rebuild without the flag). The
`build-stats` flag and the analyzer/plugin in the cabal store are harmless to
leave in place.
