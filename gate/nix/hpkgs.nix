{ pkgs ? import ./pkgs.nix { }
,
}:
let
  # Decision: lib.fileset.toSource for fine grained source filtering, copied
  # from haskell-template-project. Alternatives considered: passing ../.
  # directly (rebuilds on any nix/tooling change), cleanSource (still includes
  # too much). Listing the build inputs explicitly keeps editing nix/, the
  # makefile or .hlint.yaml from invalidating the haskell build cache.
  src = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ../app
      ../src
      ../test
      ../vibes-gate.cabal
      ../LICENSE
      ../Changelog.md
    ];
  };
in
pkgs.haskellPackages.override {
  overrides = hnew: _hold: {
    vibes-gate = hnew.callCabal2nix "vibes-gate" src { };
  };
}
