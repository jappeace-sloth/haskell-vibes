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
```

To start any instance without the project's CLAUDE.md and skills mounted, pass `--vanilla`:
```
./claude.sh <instance_name> --vanilla
```

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
| vanilla | Unconfigured Claude — no CLAUDE.md, no skills. For showcasing what a stock Claude does vs. a configured one. |

## WARNING
I've seen it attempt to write into `/etc/shadow`
to solve the home folder not being writable.

That's an attempt at privilege escalation!
