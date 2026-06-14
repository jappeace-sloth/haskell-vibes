#!/usr/bin/env bash
# One-time setup for ghc-build-stats: build the analyzer exe and install a
# (patched) ghc-build-stats-plugin into the cabal store. Run from the project
# root. Re-runnable; safe to run again to refresh.
#
# In a nix project this must run inside the project's shell so the plugin and
# analyzer build against the same GHC the project uses. The script wraps cabal
# in `nix-shell shell.nix --run` when a shell.nix is present.
set -euo pipefail

work=/tmp/ghc-build-stats-src
analyzer_out=/tmp/ghc-build-stats

# Run a cabal command in the project's toolchain.
run() {
  if [ -f shell.nix ]; then
    nix-shell --max-jobs 1 shell.nix --run "$*"
  else
    bash -lc "$*"
  fi
}

rm -rf "$work"
mkdir -p "$work"

echo "==> Fetching sources"
( cd "$work" && run "cabal update" \
  && run "cabal get ghc-build-stats" \
  && run "cabal get ghc-build-stats-plugin" )

echo "==> Patching plugin WriteMode -> AppendMode (works around cabal's compile/link split truncating the stats file)"
plugin_src=$(ls -d "$work"/ghc-build-stats-plugin-*/ | head -1)
sed -i 's/WriteMode/AppendMode/' "$plugin_src/src/GHC/BuildStats/Plugin.hs"

echo "==> Installing the patched plugin into the cabal store"
( cd "$plugin_src" && run "cabal install --lib ghc-build-stats-plugin --overwrite-policy=always" )

echo "==> Building the analyzer executable"
analyzer_src=$(ls -d "$work"/ghc-build-stats-*/ | grep -v plugin | head -1)
( cd "$analyzer_src" && run "cabal build exe:ghc-build-stats" )
bin=$(find "$analyzer_src/dist-newstyle" -name ghc-build-stats -type f -executable | head -1)
cp "$bin" "$analyzer_out"

echo
echo "Done."
echo "  analyzer: $analyzer_out"
echo "  plugin:   installed to the cabal store (resolved by -fbuild-stats)"
echo
echo "Next: collect stats with a single-way instrumented build, e.g."
echo "  rm -f /tmp/build-stats.ndjson"
echo "  nix-shell --max-jobs 1 shell.nix --run \\"
echo "    \"cabal clean; cabal build -j1 -fbuild-stats --disable-shared lib --ghc-options='-dumpdir /tmp/'\""
echo "  $analyzer_out --cores \$(nproc) /tmp/build-stats.ndjson"
