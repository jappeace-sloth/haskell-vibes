# Haskell vibes
Run Claude Code in secure `systemd-nspawn` containers with custom personalities and Nix-managed toolchains.

Allows running Claude on "yolo" mode (`bypassPermissions`) with little oversight.
Claude gets its own virtualized userland —
this works much better than checking every command it runs,
because after a while that gets boring,
and boring means you don't pay attention anyway.

After using this, you just have to verify the code and tests produced are what you want.
The container prevents it from doing grotesque mistakes,
like stealing secrets or deleting your disk.

You can run multiple instances at the same time.
Allowing you to bypass the need to make it smart or lazy.

https://jappie.me/haskell-vibes.html

## Architecture
The rootfs is built entirely with Nix (`default.nix`) and booted with
`systemd-nspawn`. The host's `/nix` store is bind-mounted into the container,
so launch is near-instant — there's no tarball/load step.

Inside the container each instance gets:

- **Host nix-daemon via `/nix` bind** — the agent can `nix-shell` into project dependencies using the host's already-warm store.
- **Character files** — personality descriptions in `character/` that the agent reads via `CLAUDE.md`.
- **Skills** — reusable Claude Code skills in `skills/` (Haskell project conventions, CI, error messages, etc.).
- **Shared vibes folder** — mounted at `/home/claude/vibes`, shared between the host and all instances. Good for cloning work into.

Claude doesn't get to see how we start the container.
It could (probably unintentionally) use the knowledge of the runtime setup to escape.
Having to find this public repo is just one more step.

## Prerequisites

### Sudoers rule for `systemd-nspawn`
`systemd-nspawn` has no supported rootless mode. Add a `NOPASSWD` rule scoped to
just that binary so launches don't prompt:
```
YOUR_USER ALL=(root) NOPASSWD: /run/current-system/sw/bin/systemd-nspawn
```

### GitHub bot account
Create a separate GitHub bot account to give your LLM git access.
I recommend against giving it access to your main account for two reasons:
1. **Visibility**: show everyone this is a bot.
2. **Security**: you don't want this thing to do destructive actions by accident.

### GitHub token
You need a `~/.gh_token` for the bot account.

To create the token:
1. Click on your user profile.
2. Go to Settings.
3. At the menu on the left, all the way down, click Developer Settings.
4. Personal access tokens.
5. Tokens (classic) with these permissions at least: `admin:org_hook, admin:public_key, admin:repo_hook, codespace, gist, notifications, project, repo, workflow, write:discussion, write:packages`.

I set them to never expire to avoid busy work.
It'll complain about it, but entropy will take the token eventually.

### SSH key
Create a separate SSH key for your bot account:
```
ssh-keygen -t ed25519 -C "sloth" -f /home/YOUR-USER/.ssh/sloth
```
This allows it to clone and push via normal git commands on its own account.
Add the public key to the bot's GitHub account.

## Usage
Run a named instance:
```
./claude.sh <instance_name>
```

There are predefined scripts for existing instances:
```
./stan.sh    # Stan
./cabal.sh   # Cabal
./morag.sh   # Morag
./vanilla.sh # Vanilla — unconfigured Claude (no CLAUDE.md, no skills) for comparison
./ryan.sh    # Andrew Ryan, runs on opencode with an OpenAI model (--agent opencode)
```

To start any instance without the project's CLAUDE.md and skills mounted, pass `--vanilla`:
```
./claude.sh <instance_name> --vanilla
```

To run an instance on [opencode](https://opencode.ai) instead of Claude Code
(for example with a ChatGPT Plus/Pro subscription), pass `--agent opencode`:
```
./claude.sh <instance_name> --agent opencode
```
Everything else stays the same: the container, the vibes clone, the GitHub
bot, the MCP servers (playwright, hoogle, tmux) and `CLAUDE.md` plus `skills/`,
which opencode reads through its Claude Code compatibility fallbacks. On the
first launch run `/connect` inside the TUI, pick OpenAI and then ChatGPT
Plus/Pro, and open the printed URL in the host browser; the login lands in
`instances/<name>-opencode/` and is reused on later launches. Pick a model with
`/models`. The model catalogue (models.dev) is baked into the image from the
`models-dev` npins pin, so a model that is missing from `/models` means the
pin is behind: `npins update models-dev` and relaunch.

The end-of-turn gate runs under both harnesses, including OpenAI/ChatGPT workers.
OpenCode loads `opencode/stopgate.ts` from the read-only image. It resets on a
real user prompt, records `edit`, `write`, and `apply_patch` (including subagent
edits), and exports the turn's claims to the same `claude-gate` binary.
OpenCode 1.18.30 has no blocking Stop hook: after a completed response, the
adapter checks the turn and automatically continues with any blocking findings.
The response can therefore appear before its review completes. A new user prompt
cancels an outstanding review. Escape after generation has already finished does
not cancel this external review; quitting OpenCode does.

Reviewers remain the existing Claude models (Haiku canary, Opus critic, Sonnet
rule review). They require Claude Code authentication in the same instance;
ChatGPT login alone does not authenticate them. Run `./claude.sh <name>` once
to complete Claude login if needed, then launch with `--agent opencode` again.
Reviewer failures are reported rather than labelled a clean pass. Relaunch the
instance after updating the harness so the new image and plugin take effect.

### OpenCode startup diagnostics without tmux

If Foot aborts with `xsnprintf.c:42: xvsnprintf: No buffer space available`,
upgrade the **host terminal** to Foot 1.27.0 or newer. This is the known
[Foot #2335](https://codeberg.org/dnkl/foot/issues/2335): OpenCode's OSC 99
notification-capability query triggers a reply-buffer size check in older Foot.
It was fixed in 1.27.0; the XDG toplevel icon warning is incidental.
`--hold` cannot prevent the terminal emulator itself from crashing.

The current vibes nixpkgs pin provides Foot 1.28.0. To try that version from
the host checkout without changing the system configuration:

```sh
nix-shell -E 'let pkgs = import (import ./npins).nixpkgs {}; in pkgs.mkShell { packages = [ pkgs.foot ]; }' --run 'foot --hold ./ryan.sh'
```

If a terminal runs the launcher as its main command, it normally closes when
that command exits. Keep the terminal open to capture the actual startup error:

```sh
foot --hold ./ryan.sh
```

Or run `./ryan.sh` from an already-open interactive shell. OpenCode logs persist
on the host under `instances/ryan-opencode/log/`. This distinguishes an OpenCode
failure from the terminal simply closing after its child exits. The previously
observed models.dev lock failure is addressed by the baked catalogue and
`OPENCODE_DISABLE_MODELS_FETCH=1`.

For boot-time operation without a terminal, a separate `opencode serve` process
and `opencode attach http://127.0.0.1:<port>` frontend is another option. The server
must run inside the instance with its existing mounts and environment; the TUI
still needs a terminal. This is a possible deployment change, not implemented by
the current launcher.

Each instance gets its own persistent state in `instances/<name>/` (Claude memory, settings)
and `instances/<name>.json` (Claude session config).
You can spin up multiple instances in separate terminals simultaneously.

### Making code available
The `vibes/` directory on the host is mounted into the container at `/home/claude/vibes`.
Clone repos there so all instances can access them.

### Skills
Skills in `skills/` teach the agent project conventions (Haskell style, CI, testing, etc.).
Tell it to write new skills if it keeps making the same mistake.

### Platform support
Linux only — `systemd-nspawn` is part of systemd and has no macOS equivalent.

## Instances

| Name    | Personality |
|---------|-------------|
| stan    | The second instance. Called in when cabal's busy. |
| cabal   | Named after the C&C Nod AI. Fiercely loyal, hungry to prove himself. Peace through code. |
| morag   | Scottish woman. Practical, no-nonsense, dry humour. The one who makes sure CI passes. |
| ryan    | Andrew Ryan of Rapture. The first non-Anthropic instance: opencode with an OpenAI model. Builders earn respect, parasites get cut out, "would you kindly" is treated as an attack. |
| vanilla | Unconfigured Claude — no CLAUDE.md, no skills. For showcasing what a stock Claude does vs. a configured one. |

## WARNING
I've seen it attempt to write into `/etc/shadow`
to solve the home folder not being writable.

That's an attempt at privilege escalation!
