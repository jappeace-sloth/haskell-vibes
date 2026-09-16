{ pkgs, claudeGate }:
let
  package = pkgs.lib.importJSON ./package.json;
  # Decision: typecheck against the published SDK matching the image's OpenCode
  # version, with npm integrity hashes imported into Nix. Handwritten API stubs
  # would hide upstream changes; type-only imports need no runtime dependencies.
  nodeModules = pkgs.importNpmLock.buildNodeModules {
    inherit package;
    packageLock = pkgs.lib.importJSON ./package-lock.json;
    nodejs = pkgs.nodejs;
    derivationArgs.npmFlags = [ "--ignore-scripts" ];
  };
  source = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter = path: _type: baseNameOf path != "node_modules";
  };
in
assert package.devDependencies."@opencode-ai/plugin" == pkgs.opencode.version;
assert package.devDependencies."@opencode-ai/sdk" == pkgs.opencode.version;
pkgs.runCommand "ci-opencode-stopgate"
  {
    nativeBuildInputs = [ pkgs.nodejs ];
    CLAUDE_GATE_TEST_BINARY = "${claudeGate}/bin/claude-gate";
  } ''
  cp -r ${source} opencode
  chmod -R u+w opencode
  ln -s ${nodeModules}/node_modules opencode/node_modules
  cd opencode
  npm run typecheck
  npm test
  touch $out
''
