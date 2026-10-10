#!/usr/bin/env bash
# Runs the launcher's Claude Code command (agent-command.sh) against
# recording_provider.py and checks the system prompt the model would receive.
# Usage: system-prompt.sh <vibes checkout>
set -euo pipefail

VIBES="$1"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$VIBES/agent-command.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

FIXTURE_INSTRUCTION="Fixture instruction: answer in Dutch."
export HOME="$SCRATCH/home"
mkdir -p "$HOME/.claude" "$SCRATCH/work"
echo "$FIXTURE_INSTRUCTION" > "$HOME/.claude/CLAUDE.md"
echo '{"hasCompletedOnboarding": true}' > "$HOME/.claude.json"

# Prints the recorded /v1/messages request body of one `claude -p` turn
# launched the way claude.sh launches instance $1 (vanilla flag 0 or 1).
record_turn() {
    local requests="$SCRATCH/requests-$1"
    python3 "$TEST_DIR/recording_provider.py" "$requests" "$SCRATCH/port-$1" > "$SCRATCH/provider-$1.log" 2>&1 &
    local provider=$!
    while [ ! -f "$SCRATCH/port-$1" ]; do
        if ! kill -0 "$provider" 2> /dev/null; then
            echo "FATAL: recording_provider.py exited before listening:" >&2
            cat "$SCRATCH/provider-$1.log" >&2
            exit 1
        fi
        sleep 0.1
    done
    set_agent_command claude "$1"
    # set -e is off inside the $(record_turn ...) substitution, so a claude
    # crash after its first request has to be caught explicitly.
    local claude_status=0
    (cd "$SCRATCH/work" && env -u CLAUDE_CONFIG_DIR \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$SCRATCH/port-$1")" \
        ANTHROPIC_API_KEY=fixture \
        DISABLE_AUTOUPDATER=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        timeout 120 "${AGENT_COMMAND[@]}" -p "hi" < /dev/null > /dev/null) || claude_status=$?
    kill "$provider"
    if [ "$claude_status" -ne 0 ]; then
        echo "FATAL: claude exited with status $claude_status (vanilla flag $1)" >&2
        exit 1
    fi
    jq -s 'map(select(.path | startswith("/v1/messages")) | .body | select(.system))
           | if length == 0 then error("claude sent no /v1/messages request") else .[0] end' \
        "$requests"/*.json
}

system_prompt_length() {
    jq '[.system[] | .text | length] | add'
}

configured_request="$(record_turn 0)"
vanilla_request="$(record_turn 1)"

configured_length="$(system_prompt_length <<< "$configured_request")"
vanilla_length="$(system_prompt_length <<< "$vanilla_request")"
echo "system prompt: vanilla $vanilla_length characters, configured $configured_length"

# The stock directives run to thousands of characters; what remains with the
# empty override is Claude Code's billing header and one-line identity.
if [ "$vanilla_length" -le 2000 ]; then
    echo "FAIL: vanilla system prompt has only $vanilla_length characters; the fixture no longer sees the stock directives" >&2
    exit 1
fi
if [ "$configured_length" -gt 300 ]; then
    echo "FAIL: configured instance still sends a $configured_length character system prompt:" >&2
    jq -r '.system[] | .text' <<< "$configured_request" >&2
    exit 1
fi
if ! jq -e --arg instruction "$FIXTURE_INSTRUCTION" \
        '.messages | tostring | contains($instruction)' <<< "$configured_request" > /dev/null; then
    echo "FAIL: configured instance no longer sends ~/.claude/CLAUDE.md" >&2
    exit 1
fi
echo "PASS"
