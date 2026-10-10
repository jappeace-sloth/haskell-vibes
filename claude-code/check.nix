{ sources }:
let
  # The same unfree nixpkgs import as default.nix, so the check runs the
  # claude-code binary the image ships.
  pkgs = import sources.nixpkgs { config.allowUnfree = true; };
  launcher = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = ../agent-command.sh;
  };
in
pkgs.runCommand "ci-claude-code-system-prompt"
  {
    nativeBuildInputs = [ pkgs.bash pkgs.claude-code pkgs.coreutils pkgs.jq pkgs.python3 ];
  } ''
  bash ${./test}/system-prompt.sh ${launcher}
  touch $out
''
