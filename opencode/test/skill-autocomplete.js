// Run with `node --test opencode/test/skill-autocomplete.js` and the patched
// opencode and tmux on PATH. Drives the real TUI in a private tmux server and
// checks that typing a skill's prefix after `/` suggests that skill.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { access, copyFile, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const userSkill = "fixture-skill";

test("the TUI's / autocomplete suggests the user's skills", { timeout: 60000 }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "opencode-autocomplete-test-"));
  // A unix socket path may not exceed ~108 bytes, which a long TMPDIR does.
  const socketDirectory = await mkdtemp(await access("/tmp").then(() => "/tmp/oc-", () => join(tmpdir(), "oc-")));
  const socket = join(socketDirectory, "tmux");
  const tmux = (...args) => execFileSync("tmux", ["-S", socket, ...args], { encoding: "utf8" });
  let screen = "";
  try {
    // The image mounts the user's skills at ~/.claude/skills.
    await mkdir(join(temporary, ".claude", "skills", userSkill), { recursive: true });
    await writeFile(join(temporary, ".claude", "skills", userSkill, "SKILL.md"),
      `---\nname: ${userSkill}\ndescription: Fixture skill installed by the user.\n---\nFixture skill body.\n`);
    const configDirectory = join(temporary, "config", "opencode");
    await mkdir(configDirectory, { recursive: true });
    // Same offline dependency setup as server-smoke.js: no npm registry in the sandbox.
    if (process.env.OPENCODE_TEST_NODE_MODULES) {
      await symlink(process.env.OPENCODE_TEST_NODE_MODULES, join(configDirectory, "node_modules"));
      await copyFile(new URL("../package.json", import.meta.url), join(configDirectory, "package.json"));
      await copyFile(new URL("../package-lock.json", import.meta.url), join(configDirectory, "package-lock.json"));
    }
    // No turn is sent, so the provider only has to exist for the TUI to pick a model.
    await writeFile(join(configDirectory, "opencode.json"), JSON.stringify({
      "$schema": "https://opencode.ai/config.json",
      model: "fixture/fixture", small_model: "fixture/fixture", autoupdate: false, permission: "allow",
      provider: { fixture: {
        npm: "@ai-sdk/openai-compatible", name: "Local fixture",
        options: { baseURL: "http://127.0.0.1:9/v1", apiKey: "test-only" },
        models: { fixture: { name: "Fixture", limit: { context: 32000, output: 1024 } } },
      } },
    }));

    // A fresh tmux server inherits this environment, and the TUI inherits it from tmux.
    execFileSync("tmux", ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-x", "160", "-y", "48", "-c", temporary, "opencode"], {
      cwd: temporary,
      env: {
        PATH: process.env.PATH, HOME: temporary, TMPDIR: temporary, TERM: "xterm-256color",
        XDG_CONFIG_HOME: join(temporary, "config"), XDG_DATA_HOME: join(temporary, "data"),
        XDG_CACHE_HOME: join(temporary, "cache"), XDG_STATE_HOME: join(temporary, "state"),
        OPENCODE_DISABLE_MODELS_FETCH: "1", OPENCODE_DISABLE_DEFAULT_PLUGINS: "1",
      },
    });
    for (let attempt = 0; attempt < 300 && !screen.includes("Ask anything"); attempt += 1) {
      await new Promise((accept) => setTimeout(accept, 100));
      screen = tmux("capture-pane", "-p");
    }
    assert.match(screen, /Ask anything/, "the TUI prompt never appeared");

    tmux("send-keys", "-l", `/${userSkill.slice(0, -2)}`);
    for (let attempt = 0; attempt < 100 && !screen.includes(`/${userSkill}:`); attempt += 1) {
      await new Promise((accept) => setTimeout(accept, 100));
      screen = tmux("capture-pane", "-p");
    }
    assert.ok(screen.includes(`/${userSkill}:skill`), screen);
  } finally {
    // tmux exits with its last session, so a TUI that died leaves no server to kill.
    try { tmux("kill-server"); } catch (error) {
      if (!/no server running|error connecting/.test(String(error.stderr))) throw error;
    }
    await rm(temporary, { recursive: true, force: true });
    await rm(socketDirectory, { recursive: true, force: true });
  }
});
