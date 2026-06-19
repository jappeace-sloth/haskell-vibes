#!/bin/sh
set -e

# /nix is bind-mounted read-write from the host; the host's nix-daemon
# socket is already there. Don't touch it.

# The env directory's /home/claude is rooted at root:0555 (Nix store perms),
# so claude can't write to it. Fix ownership before dropping privileges.
chown "${CLAUDE_UID}:${CLAUDE_GID}" /home/claude /home/claude/.ssh
chmod 755 /home/claude
chmod 700 /home/claude/.ssh

# The SSH key is mounted with --bind-ro, so its metadata can't be changed
# from inside the container (chown/chmod fail with "Read-only file system").
# It needs no fixing anyway: the host file is already mode 600 and owned by
# the host uid, which is CLAUDE_UID inside, so ssh accepts it as-is. Don't
# attempt the change just to swallow the guaranteed error.

# Start the shared Playwright MCP server as the claude user, in the background,
# before handing off to claude. Both the main agent and nested gate critics then
# connect to one warm browser over HTTP (see claude.sh MCP_CONFIG) instead of
# each cold-spawning chromium. Wait up to ~10s (50 * 0.2s) for the listener so
# the first claude connects cleanly, then proceed regardless. The probe targets
# "/" rather than the configured "/mcp" on purpose: any HTTP reply proves the
# port is accepting connections, whereas a GET to the streamable-HTTP "/mcp" can
# open a stream and block until the timeout. We only need to know it is up.
su-exec "${CLAUDE_UID}:${CLAUDE_GID}" playwright-mcp-sidecar >/tmp/playwright-mcp.log 2>&1 &
playwright_wait=0
while [ "$playwright_wait" -lt 50 ] && ! curl -s -o /dev/null --max-time 1 http://127.0.0.1:9223/; do
    playwright_wait=$((playwright_wait + 1))
    sleep 0.2
done

exec su-exec "${CLAUDE_UID}:${CLAUDE_GID}" "$@"
