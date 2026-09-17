// Run with `node --test opencode/test/server-smoke.js` and opencode on PATH.
// A real OpenCode server talks only to a local provider fixture. No account or
// model credentials are loaded, and no real model is invoked.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

async function providerFixture(request, response) {
  let body = "";
  for await (const chunk of request) { body += chunk; }
  const critic = JSON.stringify(JSON.parse(body).messages).includes("You are an adversarial correctness critic.");
  response.writeHead(200, { "content-type": "text/event-stream" });
  for (const choice of [
    { delta: { role: "assistant", content: critic ? "CHALLENGE: fixture reviewer found a problem." : "Local fixture answer." }, finish_reason: null },
    { delta: {}, finish_reason: "stop" },
  ]) {
    response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, ...choice }] })}\n\n`);
  }
  response.end("data: [DONE]\n\n");
}

async function requestJSON(url, body) {
  const response = await fetch(url, { signal: AbortSignal.timeout(10000), ...(body === undefined ? {} : {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  }) });
  assert.ok(response.ok, `${response.status}: ${await response.clone().text()}`);
  return response.status === 204 ? undefined : response.json();
}

for (const realGate of [false, true]) {
test(`OpenCode resumes a rejected turn using ${realGate ? "the real gate and an OpenCode reviewer" : "a fixture gate"}`, { timeout: 60000 }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "opencode-server-test-"));
  const provider = createServer(providerFixture).listen(0, "127.0.0.1");
  await once(provider, "listening");
  let server;
  let output = "";
  try {
    if (realGate) assert.ok(isAbsolute(process.env.CLAUDE_GATE_TEST_BINARY ?? ""), "Set CLAUDE_GATE_TEST_BINARY to the built gate's absolute path");
    // Supply OpenCode's startup dependencies from the Nix lock import so the
    // sandbox never needs an npm registry connection during plugin loading.
    if (process.env.OPENCODE_TEST_NODE_MODULES) {
      const configDirectory = join(temporary, "config", "opencode");
      await mkdir(configDirectory, { recursive: true });
      await symlink(process.env.OPENCODE_TEST_NODE_MODULES, join(configDirectory, "node_modules"));
      await copyFile(new URL("../package.json", import.meta.url), join(configDirectory, "package.json"));
      await copyFile(new URL("../package-lock.json", import.meta.url), join(configDirectory, "package-lock.json"));
    }
    // Match the installed image: only the .ts plugin, no node_modules beside it.
    const plugin = join(temporary, "stopgate.ts");
    await copyFile(new URL("../stopgate.ts", import.meta.url), plugin);
    await writeFile(join(temporary, "calls"), "");
    await writeFile(join(temporary, "claude"), `#!${process.execPath}\nprocess.stderr.write('Unexpected Claude reviewer'); process.exit(99);\n`, { mode: 0o755 });
    await writeFile(join(temporary, "claude-gate"), `#!${process.execPath}
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
fs.appendFileSync(${JSON.stringify(join(temporary, "calls"))}, process.argv[2] + '\\n');
if (${realGate}) {
  const result = require('node:child_process').spawnSync(${JSON.stringify(process.env.CLAUDE_GATE_TEST_BINARY)}, process.argv.slice(2), { input: JSON.stringify(input), encoding: 'utf8' });
  if (result.error) throw result.error;
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  process.exit(result.status);
}
if (process.argv[2] !== 'stop-gate') process.exit(0);
const marker = ${JSON.stringify(join(temporary, "reviewed"))};
if (fs.existsSync(marker)) process.stdout.write(JSON.stringify({systemMessage: 'gate clear: critique'}));
else {
  fs.writeFileSync(marker, '');
  process.stdout.write(JSON.stringify({decision: 'block', reason: 'Explain the result again after review.'}));
}
`, { mode: 0o755 });
    const config = {
      "$schema": "https://opencode.ai/config.json",
      plugin: [pathToFileURL(plugin).href],
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
        PATH: `${temporary}:${process.env.PATH}`, HOME: temporary, TMPDIR: temporary,
        XDG_CONFIG_HOME: join(temporary, "config"), XDG_DATA_HOME: join(temporary, "data"),
        XDG_CACHE_HOME: join(temporary, "cache"), XDG_STATE_HOME: join(temporary, "state"),
        OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_DISABLE_MODELS_FETCH: "1",
        OPENCODE_DISABLE_DEFAULT_PLUGINS: "1", OPENCODE_DISABLE_EXTERNAL_SKILLS: "1",
        OPENCODE_DISABLE_PROJECT_CONFIG: "1",
        CLAUDE_SKIP_HOURS_CHECK: "1",
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
    await requestJSON(`${address}/session/${session.id}/prompt_async`, {
      model: { providerID: "fixture", modelID: "fixture" },
      parts: [{ type: "text", text: "Reply briefly." }],
    });
    let calls;
    for (let attempt = 0; attempt < 600; attempt += 1) {
      calls = (await readFile(join(temporary, "calls"), "utf8")).trim().split("\n");
      if (calls.filter((command) => command === "stop-gate").length >= 2) break;
      await new Promise((accept) => setTimeout(accept, 50));
    }
    assert.deepEqual(calls, ["reset", "stop-gate", "stop-gate"], output);
    const messages = await requestJSON(`${address}/session/${session.id}/message`);
    assert.equal(messages.filter(({ info }) => info.role === "assistant" && info.finish === "stop").length, 2);
    assert.ok(messages.some(({ parts }) => parts.some((part) => part.synthetic && (realGate
      ? part.text?.includes("CHALLENGE: fixture reviewer found a problem.")
      : part.text === "Explain the result again after review."))));
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
}
