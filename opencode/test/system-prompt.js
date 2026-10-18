// Run with `node --test opencode/test/system-prompt.js` and the patched opencode
// and jq on PATH. A real OpenCode server sends one turn to a local provider
// fixture that records the request, so the test sees exactly what the model
// receives. The config comes from the launcher's write_opencode_config.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const userInstruction = "Fixture instruction: answer in Dutch.";
const userSkill = "fixture-skill";
const launcherConfig = process.env.OPENCODE_LAUNCHER_CONFIG
  ?? new URL("../../opencode-config.sh", import.meta.url).pathname;

// opencode.json as claude.sh writes it for a configured (non-vanilla) instance
// without MCP servers, pointed at the fixture provider. The stopgate plugin
// path only exists in the image, so it is dropped.
async function launcherOpencodeConfig(configDirectory, providerPort) {
  execFileSync("bash", ["-c", '. "$1" && write_opencode_config "$2" "{}" "" 0', "-", launcherConfig, configDirectory]);
  const config = JSON.parse(await readFile(join(configDirectory, "opencode.json"), "utf8"));
  delete config.plugin;
  return {
    ...config,
    model: "fixture/fixture", small_model: "fixture/fixture",
    provider: { fixture: {
      npm: "@ai-sdk/openai-compatible", name: "Local fixture",
      options: { baseURL: `http://127.0.0.1:${providerPort}/v1`, apiKey: "test-only" },
      models: { fixture: { name: "Fixture", limit: { context: 32000, output: 1024 } } },
    } },
  };
}

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
    const configDirectory = join(temporary, "config", "opencode");
    await mkdir(configDirectory, { recursive: true });
    // The image mounts the user's skills at ~/.claude/skills, like CLAUDE.md.
    await mkdir(join(temporary, ".claude", "skills", userSkill), { recursive: true });
    await writeFile(join(temporary, ".claude", "skills", userSkill, "SKILL.md"),
      `---\nname: ${userSkill}\ndescription: Fixture skill installed by the user.\n---\nFixture skill body.\n`);
    // Same offline dependency setup as server-smoke.js: no npm registry in the sandbox.
    if (process.env.OPENCODE_TEST_NODE_MODULES) {
      await symlink(process.env.OPENCODE_TEST_NODE_MODULES, join(configDirectory, "node_modules"));
      await copyFile(new URL("../package.json", import.meta.url), join(configDirectory, "package.json"));
      await copyFile(new URL("../package-lock.json", import.meta.url), join(configDirectory, "package-lock.json"));
    }
    // The image delivers the user's instructions through ~/.claude/CLAUDE.md.
    await writeFile(join(temporary, ".claude", "CLAUDE.md"), userInstruction);
    await writeFile(join(configDirectory, "opencode.json"),
      JSON.stringify(await launcherOpencodeConfig(configDirectory, provider.address().port)));
    server = spawn("opencode", ["serve", "--hostname", "127.0.0.1", "--port", "0"], {
      cwd: temporary,
      env: {
        PATH: process.env.PATH, HOME: temporary, TMPDIR: temporary,
        XDG_CONFIG_HOME: join(temporary, "config"), XDG_DATA_HOME: join(temporary, "data"),
        XDG_CACHE_HOME: join(temporary, "cache"), XDG_STATE_HOME: join(temporary, "state"),
        OPENCODE_DISABLE_MODELS_FETCH: "1", OPENCODE_DISABLE_DEFAULT_PLUGINS: "1",
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
    assert.deepEqual([...system.matchAll(/<name>(.*)<\/name>/g)].map((match) => match[1]), [userSkill]);
    // The TUI and the v2 session runner read a separate skill registry, which
    // loads asynchronously and has no ~/.claude fallback; the user's skill
    // appearing marks it as loaded.
    let v2Skills = [];
    for (let attempt = 0; attempt < 200 && !v2Skills.includes(userSkill); attempt += 1) {
      await new Promise((accept) => setTimeout(accept, 50));
      v2Skills = (await requestJSON(`${address}/api/skill?directory=${encodeURIComponent(temporary)}`)).data.map((skill) => skill.name);
    }
    assert.deepEqual(v2Skills, [userSkill]);
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
