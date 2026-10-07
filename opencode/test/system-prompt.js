// Run with `node --test opencode/test/system-prompt.js` and the patched opencode
// on PATH. A real OpenCode server sends one turn to a local provider fixture
// that records the request, so the test sees exactly what the model receives.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const userInstruction = "Fixture instruction: answer in Dutch.";

function recordingProvider(requests) {
  return async (request, response) => {
    let body = "";
    for await (const chunk of request) { body += chunk; }
    requests.push(JSON.parse(body));
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (const choice of [
      { delta: { role: "assistant", content: "Local fixture answer." }, finish_reason: null },
      { delta: {}, finish_reason: "stop" },
    ]) {
      response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, ...choice }] })}\n\n`);
    }
    response.end("data: [DONE]\n\n");
  };
}

async function requestJSON(url, body) {
  const response = await fetch(url, { signal: AbortSignal.timeout(10000), ...(body === undefined ? {} : {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  }) });
  assert.ok(response.ok, `${response.status}: ${await response.clone().text()}`);
  return response.status === 204 ? undefined : response.json();
}

test("OpenCode sends the user's instructions without bundled directives", { timeout: 60000 }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "opencode-prompt-test-"));
  const requests = [];
  const provider = createServer(recordingProvider(requests)).listen(0, "127.0.0.1");
  await once(provider, "listening");
  let server;
  let output = "";
  try {
    // Same offline dependency setup as server-smoke.js: no npm registry in the sandbox.
    if (process.env.OPENCODE_TEST_NODE_MODULES) {
      const configDirectory = join(temporary, "config", "opencode");
      await mkdir(configDirectory, { recursive: true });
      await symlink(process.env.OPENCODE_TEST_NODE_MODULES, join(configDirectory, "node_modules"));
      await copyFile(new URL("../package.json", import.meta.url), join(configDirectory, "package.json"));
      await copyFile(new URL("../package-lock.json", import.meta.url), join(configDirectory, "package-lock.json"));
    }
    // The image delivers the user's instructions through ~/.claude/CLAUDE.md.
    await mkdir(join(temporary, ".claude"));
    await writeFile(join(temporary, ".claude", "CLAUDE.md"), userInstruction);
    const config = {
      "$schema": "https://opencode.ai/config.json",
      model: "fixture/fixture", small_model: "fixture/fixture", autoupdate: false,
      permission: "allow",
      provider: { fixture: {
        npm: "@ai-sdk/openai-compatible", name: "Local fixture",
        options: { baseURL: `http://127.0.0.1:${provider.address().port}/v1`, apiKey: "test-only" },
        models: { fixture: { name: "Fixture", limit: { context: 32000, output: 1024 } } },
      } },
    };
    server = spawn("opencode", ["serve", "--hostname", "127.0.0.1", "--port", "0"], {
      cwd: temporary,
      env: {
        PATH: process.env.PATH, HOME: temporary, TMPDIR: temporary,
        XDG_CONFIG_HOME: join(temporary, "config"), XDG_DATA_HOME: join(temporary, "data"),
        XDG_CACHE_HOME: join(temporary, "cache"), XDG_STATE_HOME: join(temporary, "state"),
        OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_DISABLE_MODELS_FETCH: "1",
        OPENCODE_DISABLE_DEFAULT_PLUGINS: "1", OPENCODE_DISABLE_EXTERNAL_SKILLS: "1",
        OPENCODE_DISABLE_PROJECT_CONFIG: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    server.stdout.on("data", (chunk) => { output += chunk; });
    server.stderr.on("data", (chunk) => { output += chunk; });
    server.on("error", (error) => { output += error.message; });
    let address;
    for (let attempt = 0; attempt < 200; attempt += 1) {
      address = output.match(/http:\/\/127\.0\.0\.1:\d+/)?.[0];
      if (address || server.exitCode !== null) break;
      await new Promise((accept) => setTimeout(accept, 50));
    }
    assert.ok(address, `OpenCode did not start: ${output}`);
    const session = await requestJSON(`${address}/session`, {});
    await requestJSON(`${address}/session/${session.id}/message`, {
      model: { providerID: "fixture", modelID: "fixture" },
      parts: [{ type: "text", text: "Reply briefly." }],
    });

    // Title generation also calls the fixture, with its own prompt and no tools.
    const turns = requests.filter((request) => (request.tools ?? []).length > 0);
    assert.equal(turns.length, 1, JSON.stringify(requests, null, 2));
    const [turn] = turns;
    const system = turn.messages.filter((message) => message.role === "system").map((message) => message.content).join("\n");
    // Stock OpenCode puts its bundled per-model prompt before the environment
    // block; with the patch the environment block comes first.
    assert.match(system, /^You are powered by the model named fixture\b/);
    assert.ok(system.includes(userInstruction), system);
    // The fixture installs no skills, so any listed skill came with OpenCode.
    assert.doesNotMatch(system, /<skill>/);
    // Git policy comes only from the user's instructions (jappeace/vibes#124).
    for (const tool of turn.tools) {
      assert.doesNotMatch(tool.function.description, /commit/i, tool.function.name);
    }
  } catch (error) {
    throw new Error(`${error.message}\nOpenCode output:\n${output}`, { cause: error });
  } finally {
    if (server && server.exitCode === null) {
      const escalation = setTimeout(() => server.kill("SIGKILL"), 2000);
      server.kill("SIGTERM");
      await once(server, "close");
      clearTimeout(escalation);
    }
    provider.closeAllConnections();
    await new Promise((accept) => provider.close(accept));
    await rm(temporary, { recursive: true });
  }
});
