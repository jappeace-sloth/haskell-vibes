#!/usr/bin/env bash
# Integration test: build the container environment and verify mcp-hoogle works.
# Run from the vibes directory. Exits 0 on success, 1 on failure.
set -euo pipefail

echo "=== Building container environment ==="
ENV_PATH=$(nix-build default.nix -A env --arg uid 1000 --arg gid 100 --no-out-link 2>&1 | tail -1)

if [ ! -d "$ENV_PATH" ]; then
  echo "FAIL: nix-build did not produce a valid path: $ENV_PATH"
  exit 1
fi

echo "Built: $ENV_PATH"

# Check manifest exists
echo ""
echo "=== Checking image manifest ==="
if [ -f "$ENV_PATH/etc/image-manifest" ]; then
  cat "$ENV_PATH/etc/image-manifest"
else
  echo "WARN: No image-manifest found (build predates manifest addition)"
fi

# Check binary exists
echo ""
echo "=== Checking mcp-hoogle binary ==="
MCP_BIN="$ENV_PATH/bin/mcp-hoogle"
if [ ! -f "$MCP_BIN" ]; then
  echo "FAIL: mcp-hoogle binary not found at $MCP_BIN"
  exit 1
fi

echo "Found: $MCP_BIN"
echo "Version: $($MCP_BIN --version 2>/dev/null || echo 'unknown')"

# Test protocol negotiation
echo ""
echo "=== Testing protocol negotiation ==="
PROTO_VERSION=$(echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  | "$MCP_BIN" serve 2>/dev/null | jq -r '.result.protocolVersion')

if [ "$PROTO_VERSION" != "2024-11-05" ]; then
  echo "FAIL: Protocol negotiation broken. Expected '2024-11-05', got '$PROTO_VERSION'"
  exit 1
fi
echo "OK: Server responds with 2024-11-05"

# Test tools listing
echo ""
echo "=== Testing tools/list ==="
TOOLS_JSON=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | "$MCP_BIN" serve 2>/dev/null | tail -1)

TOOL_COUNT=$(echo "$TOOLS_JSON" | jq '.result.tools | length')
TOOL_NAMES=$(echo "$TOOLS_JSON" | jq -r '.result.tools[].name' | sort | tr '\n' ' ')

if [ "$TOOL_COUNT" -lt 5 ]; then
  echo "FAIL: Expected at least 5 tools, got $TOOL_COUNT"
  exit 1
fi
echo "OK: $TOOL_COUNT tools found: $TOOL_NAMES"

# Test that search returns "no database" (expected without a hoogle db)
echo ""
echo "=== Testing tool call (search without database) ==="
SEARCH_RESULT=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"map"}}}' \
  | "$MCP_BIN" serve 2>/dev/null | tail -1)

SEARCH_TEXT=$(echo "$SEARCH_RESULT" | jq -r '.result.content[0].text')
if echo "$SEARCH_TEXT" | grep -qi "no database"; then
  echo "OK: Search correctly reports no database loaded"
elif echo "$SEARCH_TEXT" | grep -qi "map"; then
  echo "OK: Search returned results (database already exists)"
else
  echo "WARN: Unexpected search response: $SEARCH_TEXT"
fi

echo ""
echo "=== ALL TESTS PASSED ==="
