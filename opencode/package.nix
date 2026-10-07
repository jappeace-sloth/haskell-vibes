{ pkgs }:
# Decision: patch OpenCode so a request carries only the model, the environment
# block and the user's own instructions: no bundled per-model system prompt, and
# tool descriptions reduced to how each tool works. Alternatives: an agent
# `prompt` in opencode.json (cannot be empty, so it still injects text) or a
# plugin rewriting descriptions at runtime (keeps working silently when upstream
# adds directives). A patch fails the build instead. See no-builtin-directives.md.
pkgs.opencode.overrideAttrs (old: {
  patches = (old.patches or []) ++ [ ./no-builtin-directives.patch ];
})
