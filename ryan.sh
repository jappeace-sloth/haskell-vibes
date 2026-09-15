#! /usr/bin/env bash

set -xe

# opencode is a TUI and dies at boot when there is no controlling terminal:
# the machine-start service and any tty-less launch give it none. tmux always
# hands the command a pty, so run the container launcher inside a persistent
# session named after the instance, then attach when this script was started
# from a real terminal. A boot-time start has no tty; it just creates the
# session and returns, leaving the agent alive inside tmux.
SESSION="ryan"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" "./claude.sh ryan --agent opencode"
fi

if [ -t 1 ]; then
    tmux attach-session -t "$SESSION"
fi
