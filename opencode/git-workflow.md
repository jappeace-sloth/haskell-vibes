# Repository Git workflow

`default.nix` builds OpenCode with `git-workflow.patch`. The patch replaces
the shell tool's per-request Git restriction and the matching automatic
commit prohibitions in the default, Trinity and Beast prompts. Repository
instructions in `CLAUDE.md` or `AGENTS.md` can therefore authorize branching,
committing, pushing and creating or updating pull requests.

The separate restrictions on amending commits, force-pushing, changing Git
configuration and skipping hooks remain in place.

Build the patched package independently of the container:

```sh
nix-build --arg uid "$(id -u)" --arg gid "$(id -g)" -A opencode
./result/bin/opencode --version
```

After pulling this change, rebuild the container environment using the
normal launcher and quit and restart OpenCode inside the rebuilt environment.
An existing process still uses the old binary and its bundled prompts.

When updating nixpkgs, check that the patch still applies and inspect the
upstream prompts for equivalent restrictions in new locations. The patch
must fail the build if its target text has changed, rather than silently
shipping the old instruction again.
