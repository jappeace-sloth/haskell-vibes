#!/bin/sh
set -e

# /nix is bind-mounted read-write from the host; the host's nix-daemon
# socket is already there. Don't touch it.

# The env directory's /home/claude is rooted at root:0555 (Nix store perms),
# so claude can't write to it. Fix ownership before dropping privileges.
chown "${CLAUDE_UID}:${CLAUDE_GID}" /home/claude /home/claude/.ssh
chmod 755 /home/claude
chmod 700 /home/claude/.ssh

# Bind-mounted secrets land with host ownership; make sure the SSH key is
# readable by claude.
if [ -f /home/claude/.ssh/id_ed25519 ]; then
    chown "${CLAUDE_UID}:${CLAUDE_GID}" /home/claude/.ssh/id_ed25519 || true
    chmod 600 /home/claude/.ssh/id_ed25519 || true
fi

exec su-exec "${CLAUDE_UID}:${CLAUDE_GID}" "$@"
