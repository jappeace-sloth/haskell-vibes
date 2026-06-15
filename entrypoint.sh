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

exec su-exec "${CLAUDE_UID}:${CLAUDE_GID}" "$@"
