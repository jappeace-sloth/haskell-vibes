import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Stopgate from "../stopgate.ts";

// Exercise the exported plugin hooks and real child-process boundary. Only the
// gate executable and OpenCode SDK are fixtures; policy is tested in gate/test.
const gateFixture = `#!${process.execPath}
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
if (input.transcript_path) input.transcript = fs.readFileSync(input.transcript_path, 'utf8');
fs.appendFileSync(process.env.GATE_CALLS, JSON.stringify({command: process.argv[2], ...input}) + '\\n');
if (process.argv[2] !== 'stop-gate') process.exit(0);
const verdict = JSON.parse(fs.readFileSync(process.env.GATE_VERDICT, 'utf8'));
if (verdict?.crash) { process.stderr.write('reviewer broke'); process.exit(7); }
if (verdict?.malformed) { process.stdout.write('not json'); process.exit(0); }
if (verdict?.wait) setTimeout(() => process.stdout.write('{}'), 60000);
else process.stdout.write(JSON.stringify(verdict));
`;

function user(id = "user-1", synthetic = false) {
  return { info: { id, role: "user", agent: "build", model: { providerID: "openai", modelID: "gpt-6-astra", variant: "high" } }, parts: [{ type: "text", text: "Please fix it", synthetic }] };
}

function assistant(id = "assistant-1") {
  return { info: { id, role: "assistant", finish: "stop", time: { completed: 1 } }, parts: [{ type: "text", text: `claims from ${id}` }] };
}

beforeEach(async (context) => {
  const temporary = await mkdtemp(join(tmpdir(), "stopgate-test-"));
  const environment = { PATH: process.env.PATH, GATE_CALLS: process.env.GATE_CALLS, GATE_VERDICT: process.env.GATE_VERDICT };
  const calls = async () => (await readFile(join(temporary, "calls"), "utf8")).trim().split("\n").filter(Boolean).map(JSON.parse);
  const verdict = async (value) => writeFile(join(temporary, "verdict"), JSON.stringify(value));
  const idle = async (sessionID = "root") => hooks.event({ event: { type: "session.idle", properties: { sessionID } } });
  const prompt = async (sessionID = "root", message = user()) => hooks["chat.message"]({ sessionID }, { message: message.info, parts: message.parts });
  process.env.PATH = `${temporary}:${process.env.PATH}`;
  process.env.GATE_CALLS = join(temporary, "calls");
  process.env.GATE_VERDICT = join(temporary, "verdict");
  await writeFile(join(temporary, "claude-gate"), gateFixture, { mode: 0o755 });
  await writeFile(join(temporary, "calls"), "");
  await verdict({});
  const messages = [user(), assistant()];
  const prompts = [];
  const toasts = [];
  const logs = [];
  const client = {
    session: {
      get: async ({ path }) => ({ data: { parentID: path.id === "child" ? "root" : undefined } }),
      messages: async () => ({ data: messages }),
      promptAsync: async (request) => {
        prompts.push(request);
        const continuation = { info: { ...user("gate-message").info }, parts: request.body.parts };
        messages.push(continuation);
        await prompt(request.path.id, continuation);
        return {};
      },
    },
    tui: { showToast: async ({ body }) => { toasts.push(body); return {}; } },
    app: { log: async ({ body }) => { logs.push(body); return {}; } },
  };
  const hooks = await Stopgate({ directory: temporary, client });
  context.fixture = { temporary, calls, verdict, idle, prompt, hooks, messages, prompts, toasts, logs, client };
  context.after(async () => {
    await hooks.dispose();
    for (const [name, value] of Object.entries(environment)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await rm(temporary, { recursive: true });
  });
});

test("ChatGPT rejection resumes the same agent/model without resetting the turn", async (context) => {
  const { prompt, verdict, idle, prompts, calls, toasts, messages } = context.fixture;
  await prompt();
  await verdict({ decision: "block", reason: "Fix the failing test", systemMessage: "review rejected" });
  await idle();
  assert.equal(prompts.length, 1);
  assert.deepEqual(prompts[0].body.model, user().info.model);
  assert.equal(prompts[0].body.variant, "high");
  assert.equal(prompts[0].body.agent, "build");
  assert.equal(prompts[0].body.parts[0].text, "Fix the failing test");
  assert.deepEqual((await calls()).map((call) => call.command), ["reset", "stop-gate"]);
  assert.equal(toasts[0].message, "review rejected");
  messages.push(assistant("assistant-2"));
  await verdict({ systemMessage: "gate clear: critique" });
  await idle();
  assert.equal(prompts.length, 1);
  const exported = (await calls()).at(-1).transcript;
  assert.match(exported, /claims from assistant-1/);
  assert.match(exported, /claims from assistant-2/);
  assert.equal(exported.split("\n").filter((line) => JSON.parse(line).type === "user").length, 0);
  await prompt("root", user("user-2"));
  assert.equal((await calls()).at(-1).command, "reset");
});

test("records edit, write, and multi-file patches including deletes and moves", async (context) => {
  const { prompt, hooks, calls, temporary } = context.fixture;
  await prompt();
  await hooks["tool.execute.after"]({ tool: "edit", sessionID: "root", args: { filePath: "a.hs", oldString: "a", newString: "b" } }, {});
  await hooks["tool.execute.after"]({ tool: "write", sessionID: "root", args: { filePath: "b.hs", content: "body" } }, {});
  await hooks["tool.execute.after"]({ tool: "apply_patch", sessionID: "root", args: {} }, { metadata: { files: [
    { filePath: "a.hs", type: "delete", patch: "-b\n" },
    { filePath: "b.hs", movePath: "moved.hs", type: "move", patch: "-body\n+new\n" },
  ] } });
  const edits = (await calls()).filter((call) => call.command === "record");
  assert.deepEqual(edits.map((edit) => edit.tool_name), ["Edit", "Write", "ApplyPatch", "ApplyPatch"]);
  assert.deepEqual(edits[0].tool_input, { file_path: join(temporary, "a.hs"), old_string: "a", new_string: "b" });
  assert.equal(edits[1].tool_input.content, "body");
  assert.equal(edits[2].tool_input.patch, "-b\n");
  assert.equal(edits[3].tool_input.file_path, join(temporary, "moved.hs"));
});

test("subagent edits join the parent turn without resetting or reviewing the child", async (context) => {
  const { prompt, hooks, idle, calls } = context.fixture;
  await prompt();
  await prompt("child");
  await hooks["tool.execute.after"]({ tool: "write", sessionID: "child", args: { filePath: "child.hs", content: "body" } }, {});
  await idle("child");
  assert.deepEqual((await calls()).map((call) => [call.command, call.session_id]), [["reset", "root"], ["record", "root"]]);
});

test("duplicate idle events review a completed message only once", async (context) => {
  const { prompt, idle, calls } = context.fixture;
  await prompt();
  await Promise.all([idle(), idle()]);
  await idle();
  assert.equal((await calls()).filter((call) => call.command === "stop-gate").length, 1);
});

test("an aborted or unfinished assistant is never restarted by the gate", async (context) => {
  const { prompt, messages, idle, calls, prompts } = context.fixture;
  await prompt();
  messages[1].info.error = { name: "MessageAbortedError" };
  await idle();
  delete messages[1].info.error;
  delete messages[1].info.time.completed;
  await idle();
  assert.deepEqual((await calls()).map((call) => call.command), ["reset"]);
  assert.equal(prompts.length, 0);
});

test("a new prompt cancels an in-flight review and discards its stale verdict", async (context) => {
  const { prompt, verdict, idle, calls, prompts, logs } = context.fixture;
  await prompt();
  await verdict({ wait: true });
  const reviewing = idle();
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if ((await calls()).some((call) => call.command === "stop-gate")) break;
    await new Promise((accept) => setTimeout(accept, 10));
  }
  assert.equal((await calls()).at(-1).command, "stop-gate");
  await prompt("root", user("user-2"));
  await reviewing;
  assert.equal((await calls()).at(-1).command, "reset");
  assert.equal(prompts.length, 0);
  assert.equal(logs.length, 0);
});

for (const failure of [{ crash: true }, { malformed: true }, { decision: "block" }, null, false, [], { unrelated: true }]) {
  test(`gate failure is visible without an unhandled event rejection: ${JSON.stringify(failure)}`, async (context) => {
    const { prompt, verdict, idle, logs, toasts, prompts } = context.fixture;
    await prompt();
    await verdict(failure);
    await idle();
    assert.equal(logs.length, 1);
    assert.equal(logs[0].level, "error");
    assert.equal(toasts.at(-1).variant, "error");
    assert.match(logs[0].message, /Stopgate did not check this turn/);
    assert.equal(prompts.length, 0);
    await verdict({ decision: "block", reason: "Retry succeeded" });
    await idle();
    assert.equal(prompts.length, 1);
  });
}

test("missing patch metadata fails rather than quietly omitting the edit", async (context) => {
  const { hooks } = context.fixture;
  await assert.rejects(hooks["tool.execute.after"]({ tool: "apply_patch", sessionID: "root", args: {} }, {}), /no file diffs/);
});

test("untyped SDK tool payloads are validated before recording", async (context) => {
  const { hooks, calls } = context.fixture;
  await assert.rejects(hooks["tool.execute.after"]({
    tool: "write", sessionID: "root", args: { filePath: "a.hs", content: null },
  }, {}), /string field content/);
  await assert.rejects(hooks["tool.execute.after"]({
    tool: "apply_patch", sessionID: "root", args: {},
  }, { metadata: { files: [{ filePath: "a.hs", patch: false }] } }), /string field patch/);
  assert.deepEqual(await calls(), []);
});

test("compaction replay does not discard claims from the original prompt", async (context) => {
  const { prompt, messages, idle, calls } = context.fixture;
  await prompt();
  messages.push(user("compaction-replay"), assistant("after-compaction"));
  await idle();
  const exported = (await calls()).at(-1).transcript;
  assert.match(exported, /claims from assistant-1/);
  assert.match(exported, /claims from after-compaction/);
});

test("a user subtask command resets the gate", async (context) => {
  const { prompt, calls } = context.fixture;
  await prompt("root", { info: user().info, parts: [{ type: "subtask", prompt: "check the work" }] });
  assert.equal((await calls()).at(-1).command, "reset");
});

test("a new prompt during notification delivery suppresses the stale continuation", async (context) => {
  const { prompt, verdict, idle, client, prompts } = context.fixture;
  await prompt();
  await verdict({ decision: "block", reason: "old findings", systemMessage: "review rejected" });
  const notification = Promise.withResolvers();
  const release = Promise.withResolvers();
  client.tui.showToast = async () => { notification.resolve(); await release.promise; };
  const reviewing = idle();
  await notification.promise;
  const newPrompt = prompt("root", user("user-2"));
  await new Promise((accept) => setImmediate(accept));
  release.resolve();
  await Promise.all([reviewing, newPrompt]);
  assert.equal(prompts.length, 0);
});

test("disposal while fetching messages prevents a late review from starting", async (context) => {
  const { prompt, idle, client, messages, hooks, calls } = context.fixture;
  await prompt();
  const fetching = Promise.withResolvers();
  const release = Promise.withResolvers();
  client.session.messages = async () => { fetching.resolve(); await release.promise; return { data: messages }; };
  const reviewing = idle();
  await fetching.promise;
  const disposing = hooks.dispose();
  release.resolve();
  await Promise.all([reviewing, disposing]);
  assert.deepEqual((await calls()).map((call) => call.command), ["reset"]);
});

test("an asynchronous continuation failure stays visible and can be retried", async (context) => {
  const { prompt, idle, verdict, client, prompts, logs } = context.fixture;
  await prompt();
  await verdict({ decision: "block", reason: "review feedback" });
  const submit = client.session.promptAsync;
  client.session.promptAsync = async () => ({});
  await idle();
  assert.equal(prompts.length, 0);
  assert.match(logs.at(-1).message, /accepted the gate feedback but did not save it/);
  client.session.promptAsync = submit;
  await idle();
  assert.equal(prompts.length, 1);
});
