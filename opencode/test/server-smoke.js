// Run with `node --test opencode/test/server-smoke.js` and opencode on PATH.
// A real OpenCode server talks only to a local provider fixture. No account or
// model credentials are loaded, and no real model is invoked.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

async function providerFixture(request, response) {
  for await (const chunk of request) { void chunk; }
  response.writeHead(200, { "content-type": "text/event-stream" });
  for (const choice of [
    { delta: { role: "assistant", content: "Local fixture answer." }, finish_reason: null },
    { delta: {}, finish_reason: "stop" },
  ]) {
    response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, ...choice }] })}\n\n`);
  }
  response.end("data: [DONE]\n\n");
}

async function requestJSON(url, body) {
  const response = await fetch(url, body === undefined ? {} : {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  });
  assert.ok(response.ok, `${response.status}: ${await response.clone().text()}`);
  return response.status === 204 ? undefined : response.json();
}

test("OpenCode loads the plugin and actually resumes a rejected completed turn", { timeout: 60000 }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "opencode-server-test-"));
  const provider = createServer(providerFixture).listen(0, "127.0.0.1");
  await once(provider, "listening");
  let server;
  let output = "";
  try {
    // Match the installed image: only the .ts plugin, no node_modules beside it.
    const plugin = join(temporary, "stopgate.ts");
    await copyFile(new URL("../stopgate.ts", import.meta.url), plugin);
    await writeFile(join(temporary, "calls"), "");
    await writeFile(join(temporary, "claude-gate"), `#!${process.execPath}
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
fs.appendFileSync(${JSON.stringify(join(temporary, "calls"))}, process.argv[2] + '\\n');
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
    assert.ok(messages.some(({ parts }) => parts.some((part) => part.synthetic && part.text === "Explain the result again after review.")));
  } finally {
    if (server && server.exitCode === null) {
      server.kill("SIGTERM");
      await once(server, "close");
    }
    provider.closeAllConnections();
    await new Promise((accept) => provider.close(accept));
    await rm(temporary, { recursive: true });
  }
});
