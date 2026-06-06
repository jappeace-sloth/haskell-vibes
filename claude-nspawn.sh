#!/usr/bin/env bash
# systemd-nspawn launcher — sibling to claude.sh, kept separate so the
# docker path stays available as a fallback.
#
# Wins vs claude.sh:
#  - no `docker load` (saves 1-2 min per launch on a warm cache)
#  - nesting works from inside (no docker-seccomp clone(CLONE_NEWUSER) block)
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

# Same MCP injection as claude.sh.
MCP_CONFIG='{"playwright":{"command":"playwright-mcp","args":["--headless","--no-sandbox","--isolated","--ignore-https-errors","--executable-path","/usr/local/bin/chromium"]},"hoogle":{"command":"mcp-hoogle","args":["serve"]},"tmux":{"command":"tmux-mcp-rs","args":[]}}'
UPDATED_JSON=$(jq --argjson mcp "$MCP_CONFIG" 'del(.mcpServers) | .mcpServers = $mcp | if .projects then .projects |= map_values(del(.mcpServers)) else . end' "$INSTANCE_JSON")
echo "$UPDATED_JSON" > "$INSTANCE_JSON"

NIX_ARGS=(./default.nix --arg uid "$(id -u)" --arg gid "$(id -g)")

# Build the env (no docker image) and the nspawn entrypoint.
ENV_PATH=$(nix-build "${NIX_ARGS[@]}" -A env --no-out-link)
ENTRYPOINT_PATH=$(nix-build "${NIX_ARGS[@]}" -A entrypointNspawn --no-out-link)

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
# --ephemeral discards writable rootfs changes on exit, matching --rm.
# --resolv-conf=bind-host shares the host's /etc/resolv.conf.
exec sudo systemd-nspawn \
    --machine="$INSTANCE_NAME" \
    --hostname="$INSTANCE_NAME" \
    --directory="$ENV_PATH" \
    --ephemeral \
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
