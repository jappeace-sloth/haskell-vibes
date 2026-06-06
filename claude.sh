#!/usr/bin/env bash
# systemd-nspawn launcher for a claude-env instance.
#
# Requires sudo on systemd-nspawn — there is no supported rootless mode.
# Suggested sudoers line:
#     YOUR_USER ALL=(root) NOPASSWD: /run/current-system/sw/bin/systemd-nspawn

set -xe

if [ -z "$1" ]; then
    echo "Error: Instance name required."
    echo "Usage: $0 <instance_name> [--vanilla]"
    exit 1
fi

INSTANCE_NAME="$1"
shift

VANILLA=0
for arg in "$@"; do
    case "$arg" in
        --vanilla) VANILLA=1 ;;
        *) echo "Error: unknown argument '$arg'"; exit 1 ;;
    esac
done

mkdir -p "../vibes/$INSTANCE_NAME"

INSTANCE_DIR="$(pwd)/instances/$INSTANCE_NAME"
INSTANCE_JSON="$(pwd)/instances/${INSTANCE_NAME}.json"

if [ ! -d "$INSTANCE_DIR" ]; then
    mkdir -p "$INSTANCE_DIR"
fi

if [ -e "$INSTANCE_JSON" ] && [ ! -f "$INSTANCE_JSON" ]; then
    rm -rf "$INSTANCE_JSON"
fi

if [ ! -f "$INSTANCE_JSON" ]; then
    echo "{}" > "$INSTANCE_JSON"
fi

# Claude Code reads MCP servers from ~/.claude.json (not settings.json).
# Clear any stale per-project entries Claude Code writes during sessions.
MCP_CONFIG='{"playwright":{"command":"playwright-mcp","args":["--headless","--no-sandbox","--isolated","--ignore-https-errors","--executable-path","/usr/local/bin/chromium"]},"hoogle":{"command":"mcp-hoogle","args":["serve"]},"tmux":{"command":"tmux-mcp-rs","args":[]}}'
UPDATED_JSON=$(jq --argjson mcp "$MCP_CONFIG" 'del(.mcpServers) | .mcpServers = $mcp | if .projects then .projects |= map_values(del(.mcpServers)) else . end' "$INSTANCE_JSON")
echo "$UPDATED_JSON" > "$INSTANCE_JSON"

NIX_ARGS=(./default.nix --arg uid "$(id -u)" --arg gid "$(id -g)")

# Build the rootfs env and the entrypoint script.
ENV_PATH=$(nix-build "${NIX_ARGS[@]}" -A env --no-out-link)
ENTRYPOINT_PATH=$(nix-build "${NIX_ARGS[@]}" -A entrypoint --no-out-link)

# systemd-nspawn writes a `.#machine.<hash>` lock file in the parent dir of
# --directory= before booting. /nix/store is read-only, so we point it at a
# per-launch copy under /tmp instead. The env is a tree of symlinks into
# /nix/store, so `cp -a` is cheap and the copy still references the host store
# at runtime.
RUNTIME_ROOT="/tmp/claude-rootfs.${INSTANCE_NAME}.$$"
mkdir -p "$RUNTIME_ROOT"
cp -a "$ENV_PATH/." "$RUNTIME_ROOT/"

# /nix/store paths are mode 0555; cp -a preserves that, leaving the copy's
# directories read-only — we couldn't unlink their entries during cleanup,
# nor could the container land bind mounts inside them.
chmod -R u+w "$RUNTIME_ROOT"

# /home in the env is a symlink into a /nix/store path. Without replacing
# it, the container's chown of /home/claude follows the symlink through the
# --bind=/nix mount and modifies the host nix store. Recreate /home as a
# fresh user-owned tree, with the bind-mount targets pre-made.
rm -rf "$RUNTIME_ROOT/home"
mkdir -p \
    "$RUNTIME_ROOT/home/claude/.ssh" \
    "$RUNTIME_ROOT/home/claude/.claude" \
    "$RUNTIME_ROOT/home/claude/vibes" \
    "$RUNTIME_ROOT/home/claude/character"
touch "$RUNTIME_ROOT/home/claude/.claude.json"

# Cleanup is best-effort. If nspawn left a mount-point dir or a root-owned
# entry we can't reach, leave it — /tmp clears on reboot anyway.
trap 'rm -rf "$RUNTIME_ROOT" 2>/dev/null || true' EXIT

# Vanilla mode skips the project's CLAUDE.md and skills mounts.
CONFIG_BINDS=()
if [ "$VANILLA" -eq 0 ]; then
    CONFIG_BINDS+=("--bind-ro=$(pwd)/CLAUDE.md:/home/claude/.claude/CLAUDE.md")
    CONFIG_BINDS+=("--bind-ro=$(pwd)/skills:/home/claude/.claude/skills")
fi

REDDIT_SETENV=()
if [ -f ~/.reddit_secret ]; then
    REDDIT_SETENV+=("--setenv=REDDIT_USERNAME=jappeace-sloth")
    REDDIT_SETENV+=("--setenv=REDDIT_PASSWORD=$(cat ~/.reddit_secret)")
fi

KVM_BIND=()
if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_BIND=("--bind=/dev/kvm")
fi

# --as-pid2 puts systemd-stub at PID 1 so zombies from chromium/playwright
# get reaped instead of accumulating.
# --resolv-conf=bind-host shares the host's /etc/resolv.conf.
# (No `exec sudo …` — we want the EXIT trap to run after nspawn returns.)
sudo systemd-nspawn \
    --machine="$INSTANCE_NAME" \
    --hostname="$INSTANCE_NAME" \
    --directory="$RUNTIME_ROOT" \
    --as-pid2 \
    --resolv-conf=bind-host \
    --bind=/nix \
    --bind="$INSTANCE_JSON:/home/claude/.claude.json" \
    --bind="$INSTANCE_DIR:/home/claude/.claude" \
    --bind="$(pwd)/settings.json:/home/claude/.claude/settings.json" \
    "${CONFIG_BINDS[@]}" \
    --bind="$(pwd)/../vibes/$INSTANCE_NAME:/home/claude/vibes" \
    --bind-ro="$(pwd)/character:/home/claude/character" \
    --bind-ro="$HOME/.ssh/sloth:/home/claude/.ssh/id_ed25519" \
    --tmpfs=/tmp:rw,mode=1777 \
    --setenv=INSTANCE_NAME="$INSTANCE_NAME" \
    --setenv=TERM=xterm-256color \
    --setenv=COLORTERM=truecolor \
    --setenv=HOME=/home/claude \
    --setenv=CLAUDE_UID="$(id -u)" \
    --setenv=CLAUDE_GID="$(id -g)" \
    --setenv=GH_TOKEN="$(cat ~/.gh_token)" \
    "${REDDIT_SETENV[@]}" \
    "${KVM_BIND[@]}" \
    "$ENTRYPOINT_PATH" claude
