{
  hpkgs ? import ./nix/hpkgs.nix {},
  pkgs ? import ./nix/pkgs.nix {},
}:
hpkgs.shellFor {
  packages = ps: [ ps."claude-gate" ];
  withHoogle = false;

  buildInputs = [
    hpkgs.haskell-language-server
    pkgs.ghcid
    pkgs.cabal-install
  ];
}
