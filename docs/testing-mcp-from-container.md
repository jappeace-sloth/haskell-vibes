# Testing MCP Servers From Within the Container

## Problem

We build Docker images with `nix-build` containing MCP servers (e.g. mcp-hoogle).
We want agents inside the container to verify the MCP server works end-to-end
without requiring a human to rebuild and relaunch.

## Verifying Container Build State

Check `/etc/image-manifest`:
```bash
cat /etc/image-manifest
```
Expected:
```
mcp-hoogle-rev: <7-char hash>
mcp-server-rev: <7-char hash>
built-epoch: <unix timestamp>
```
If the file doesn't exist, the container predates this check.

---

## Approach 1: Direct Binary Testing (Works Now, Free)

Since Docker images are just nix derivations, the binary can be tested directly
without any container infrastructure:

```bash
# Full MCP handshake test
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
| mcp-hoogle serve 2>/dev/null | jq .

# Quick protocol version check
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
| mcp-hoogle serve 2>/dev/null | jq -r '.result.protocolVersion'
# Must output: 2024-11-05
```

This tests:
- Protocol negotiation (the 2024-11-05 fix)
- Tool listing (all 5 tools appear)
- JSON-RPC message handling

Does NOT test:
- Whether Claude Code actually picks up the server from settings.json
- MCP server discovery at session startup

## Approach 2: Claude Code Subprocess (Works Now, Costs Tokens)

Spawn a headless Claude session that initializes MCP and exercises the tools:

```bash
CLAUDECODE="" claude -p \
  "List all MCP tools available to you. Then call the search tool with query 'map'." \
  --mcp-config '{"mcpServers":{"hoogle":{"command":"mcp-hoogle","args":["serve"]}}}' \
  --strict-mcp-config \
  --allowedTools "mcp__hoogle__*" \
  --permission-mode bypassPermissions \
  --max-budget-usd 0.50 \
  --output-format json
```

Key flags:
- `CLAUDECODE=""` — unset env var that blocks nested sessions
- `--strict-mcp-config` — ignore all other MCP configs, only use ours
- `--allowedTools "mcp__hoogle__*"` — auto-approve hoogle tool calls
- `--permission-mode bypassPermissions` — no interactive prompts
- `--max-budget-usd` — cap spending

This is the **highest fidelity test** because it exercises the exact same code
path that Claude Code uses in production (protocol negotiation, tool discovery,
tool calling).

## Approach 3: MCP Inspector (Works Now, No Token Cost)

The official MCP testing tool, runs via npx:

```bash
# List tools
npx @modelcontextprotocol/inspector --cli mcp-hoogle serve --method tools/list

# Call a tool
npx @modelcontextprotocol/inspector --cli mcp-hoogle serve \
  --method tools/call --tool-name search --tool-arg query=map
```

Requires Node.js (available via `nix-shell -p nodejs`).

## Approach 4: Claude Code Debug Mode

For diagnosing why tools don't appear in a live session:

```bash
claude --debug mcp
```

Shows JSON-RPC traffic during initialization. Look for:
- Protocol version mismatch (server responds with higher version than client proposed)
- Connection timeouts
- Parse errors in JSON-RPC

Also: `/mcp` command inside a session shows server connection status and tool counts.

---

## Approaches That DON'T Work (From This Container)

### Docker-in-Docker / Socket Mounting

The container has no Docker socket mounted, no `docker` CLI, and the security
model intentionally prevents container escape. Mounting the Docker socket would
give the agent root access to the host.

### Podman Rootless

Docker's default seccomp profile blocks `clone(CLONE_NEWUSER)`. Podman cannot
create user namespaces. Would require `--security-opt seccomp=unconfined` on
the host-side `docker run`.

### Bubblewrap (bwrap)

Same seccomp restriction. Despite bwrap being in PATH, it cannot create
namespaces.

---

## Recommended Testing Workflow

For CI/automated testing of MCP server changes:

1. **Build**: `nix-build default.nix -A env --arg uid 1000 --arg gid 100`
2. **Verify manifest**: `cat result/etc/image-manifest`
3. **Protocol test**: Pipe JSON-RPC initialize + tools/list, assert response
4. **Integration test** (optional, costs tokens): `claude -p` with `--mcp-config`

For debugging "tools don't show up":

1. `cat /etc/image-manifest` — is the container even built from the right code?
2. `which mcp-hoogle` — is the binary on PATH?
3. `mcp-hoogle --version` — right version?
4. Pipe initialize JSON — does protocol negotiation return the right version?
5. `claude --debug mcp` — what does Claude Code see during startup?
