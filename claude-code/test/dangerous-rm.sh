#!/usr/bin/env bash
# Checks that settings.json answers the prompt Claude Code shows, even in
# bypassPermissions mode, before a removal it cannot vet. The model is
# recording_provider.py asking for one Bash call.
# Usage: dangerous-rm.sh <vibes checkout>
#
# Decision: a PermissionRequest hook on Bash answers "allow", so the built-in
# dangerous rm check (rm -rf ~, rm -rf $(...), rm -rf "$UNSET"/*) never waits
# for Jappie. Rejected: allow rules (the check refuses to be auto-allowed by
# them) and the undocumented CLAUDE_CODE_DISABLE_*_RM_PROMPT variables (they
# skip only two of the removal kinds). The matcher stays on Bash so
# AskUserQuestion still reaches him.
set -euo pipefail

VIBES="$1"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$VIBES/agent-command.sh"
. "$TEST_DIR/fixture.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Claude Code cannot know what a command substitution prints, so it treats
# this removal as dangerous although it only reaches the scratch target.
# shellcheck disable=SC2016
REMOVAL='rm -rf $(echo target)'

# Runs one turn whose model asks for REMOVAL under settings file $2 (case
# name $1), then prints the Bash tool result and whether the target survived.
removal_outcome() {
    local case_dir="$SCRATCH/$1"
    export HOME="$case_dir/home"
    mkdir -p "$HOME/.claude" "$case_dir/work/target"
    cp "$2" "$HOME/.claude/settings.json"
    echo '{"hasCompletedOnboarding": true}' > "$HOME/.claude.json"
    start_provider "$case_dir/provider.log" "$case_dir/requests" "$case_dir/port" "$REMOVAL"
    set_agent_command claude 0
    local claude_status=0
    fixture_turn "$case_dir/work" || claude_status=$?
    kill "$PROVIDER_PID"
    if [ "$claude_status" -ne 0 ]; then
        echo "FATAL: claude exited with status $claude_status ($1)" >&2
        exit 1
    fi
    jq -r -s '[.[].body.messages[]?.content | arrays | .[] | select(.type == "tool_result")]
              | if length == 0 then error("claude never ran the requested Bash call") else .[0].content end
              | if type == "array" then map(.text) | join("") else . end' \
        "$case_dir/requests"/*.json || exit 1
    if [ -d "$case_dir/work/target" ]; then echo "target survived"; else echo "target removed"; fi
}

# Only the permission settings: the other hooks run claude-gate, which this
# check does not ship.
jq '{permissions, hooks: {PermissionRequest: .hooks.PermissionRequest}}' "$VIBES/settings.json" > "$SCRATCH/configured.json"
jq '{permissions}' "$VIBES/settings.json" > "$SCRATCH/unhooked.json"

unhooked_outcome="$(removal_outcome unhooked "$SCRATCH/unhooked.json")"
configured_outcome="$(removal_outcome configured "$SCRATCH/configured.json")"

if [ "$(tail -n 1 <<< "$unhooked_outcome")" != "target survived" ]; then
    echo "FAIL: without the hook Claude Code ran '$REMOVAL' unasked, so this fixture no longer reaches the dangerous rm check:" >&2
    echo "$unhooked_outcome" >&2
    exit 1
fi
if [ "$(tail -n 1 <<< "$configured_outcome")" != "target removed" ]; then
    echo "FAIL: with settings.json Claude Code still holds '$REMOVAL' for a person:" >&2
    echo "$configured_outcome" >&2
    exit 1
fi
echo "PASS"
