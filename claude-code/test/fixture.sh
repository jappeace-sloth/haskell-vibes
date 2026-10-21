# shellcheck shell=bash
# Sourced by the claude-code checks, which set TEST_DIR to this directory.

# Starts recording_provider.py on <requests dir> <port file> [bash command],
# logging to <log file>, and sets PROVIDER_PID and PROVIDER_URL once it listens.
# Usage: start_provider <log file> <requests dir> <port file> [bash command]
start_provider() {
    local log="$1" port_file="$3"
    python3 "$TEST_DIR/recording_provider.py" "${@:2}" > "$log" 2>&1 &
    PROVIDER_PID=$!
    while [ ! -f "$port_file" ]; do
        if ! kill -0 "$PROVIDER_PID" 2> /dev/null; then
            echo "FATAL: recording_provider.py exited before listening:" >&2
            cat "$log" >&2
            exit 1
        fi
        sleep 0.1
    done
    PROVIDER_URL="http://127.0.0.1:$(cat "$port_file")"
}

# Runs `AGENT_COMMAND -p hi` in <work dir> against the provider at PROVIDER_URL,
# with HOME as the caller set it, and returns claude's exit status.
# Usage: fixture_turn <work dir>
fixture_turn() {
    (cd "$1" && env -u CLAUDE_CONFIG_DIR \
        ANTHROPIC_BASE_URL="$PROVIDER_URL" \
        ANTHROPIC_API_KEY=fixture \
        DISABLE_AUTOUPDATER=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        timeout 120 "${AGENT_COMMAND[@]}" -p "hi" < /dev/null > /dev/null)
}
