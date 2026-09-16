import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

/** Run the existing hook protocol without a shell or npm dependencies. */
function runGate(command, payload, directory, signal) {
  return new Promise((accept, reject) => {
    const child = spawn("claude-gate", [command], {
      cwd: directory,
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
      env: { ...process.env, CLAUDE_GATE_SHARED_PROCESS_GROUP: "1" },
    });
    let stdout = "";
    let stderr = "";
    let failure;
    let escalation;
    const terminate = (signalName) => {
      if (!child.pid) return;
      try {
        process.kill(-child.pid, signalName);
      } catch (error) {
        // ESRCH means the process group already exited during cancellation.
        if (error.code !== "ESRCH") reject(error);
      }
    };
    const abort = () => {
      terminate("SIGTERM");
      escalation ??= setTimeout(() => terminate("SIGKILL"), 1000);
    };
    const deadline = setTimeout(() => {
      failure = new Error(`claude-gate ${command} timed out. Check the reviewer logs before retrying.`);
      abort();
    }, command === "stop-gate" ? 3600000 : 30000);
    child.stdout.setEncoding("utf8").on("data", (text) => { stdout += text; });
    child.stderr.setEncoding("utf8").on("data", (text) => { stderr += text; });
    child.on("error", (error) => { failure = error; });
    child.stdin.on("error", (error) => { failure = error; abort(); });
    child.on("close", (code) => {
      clearTimeout(deadline);
      // A descendant may have redirected its pipes and outlived the leader.
      // Finish cancelling the whole group before releasing the session queue.
      terminate("SIGKILL");
      clearTimeout(escalation);
      signal?.removeEventListener("abort", abort);
      if (signal?.aborted) return accept(undefined);
      if (failure) return reject(failure);
      if (code !== 0) return reject(new Error(`claude-gate ${command} exited ${code}: ${stderr}`));
      try {
        accept(parseVerdict(stdout));
      } catch (error) {
        reject(new Error(`claude-gate ${command} returned invalid JSON: ${error.message}`));
      }
    });
    signal?.addEventListener("abort", abort, { once: true });
    child.stdin.end(JSON.stringify(payload));
    if (signal?.aborted) abort();
  });
}

/** Empty output is the hook's success protocol; other output must be an object. */
function parseVerdict(stdout) {
  const verdict = stdout.trim() ? JSON.parse(stdout) : {};
  if (!verdict || typeof verdict !== "object" || Array.isArray(verdict)
    || Object.keys(verdict).some((key) => !["decision", "reason", "systemMessage"].includes(key))
    || (verdict.systemMessage !== undefined && typeof verdict.systemMessage !== "string")) {
    throw new Error("expected an object containing decision/reason/systemMessage");
  }
  return verdict;
}

/** Serialize hooks per root session, without sharing mutable state globally. */
function sessionState(sessions, sessionID) {
  if (!sessions.has(sessionID)) {
    sessions.set(sessionID, { pending: Promise.resolve(), revision: 0, checked: undefined, controller: undefined, turnID: undefined, closing: false });
  }
  return sessions.get(sessionID);
}

/** A failed hook is reported to its caller; subsequent prompts can still reset. */
function enqueue(state, action) {
  const pending = state.pending.then(action);
  state.pending = pending.then(() => undefined, () => undefined);
  return pending;
}

/** Reset and record must also be cancellable when OpenCode shuts down. */
async function runSessionGate(context, state, command, payload) {
  if (state.closing) return;
  state.controller = new AbortController();
  try {
    await runGate(command, payload, context.directory, state.controller.signal);
  } finally {
    state.controller = undefined;
  }
}

/** Resolve subagent edits to the parent's turn instead of reviewing them twice. */
async function rootSession(client, sessionID) {
  const response = await client.session.get({ path: { id: sessionID }, throwOnError: true });
  return response.data.parentID ? rootSession(client, response.data.parentID) : sessionID;
}

/** Only genuine user input resets a turn, never gate or compaction continuations. */
function realPrompt(parts) {
  return parts.some((part) => !part.synthetic && ["text", "file", "agent", "subtask"].includes(part.type));
}

/** Translate completed OpenCode edit tools into the shared hook protocol. */
function recordedEdits(input, output, directory) {
  switch (input.tool) {
    case "edit":
      return [{ tool_name: "Edit", tool_input: {
        file_path: resolve(directory, input.args.filePath),
        old_string: input.args.oldString, new_string: input.args.newString,
      } }];
    case "write":
      return [{ tool_name: "Write", tool_input: {
        file_path: resolve(directory, input.args.filePath), content: input.args.content,
      } }];
    case "apply_patch":
      if (!Array.isArray(output.metadata?.files) || output.metadata.files.length === 0) {
        throw new Error("OpenCode apply_patch returned no file diffs. Check the stopgate adapter against the installed OpenCode version.");
      }
      return output.metadata.files.map((file) => {
        if (typeof file.patch !== "string") throw new Error(`OpenCode omitted the applied diff for ${file.filePath}. Update the stopgate adapter.`);
        return { tool_name: "ApplyPatch", tool_input: {
          file_path: resolve(directory, file.movePath ?? file.filePath), patch: file.patch,
        } };
      });
    default:
      return [];
  }
}

/** Export claims in the gate's transcript format, retaining the real turn boundary. */
function transcript(messages, turnID) {
  const boundary = turnID
    ? messages.findIndex(({ info }) => info.id === turnID)
    : messages.findLastIndex(({ info, parts }) => info.role === "user" && realPrompt(parts));
  if (boundary < 0) throw new Error("The gate's user prompt is missing from the OpenCode transcript. Send a new prompt to reset the turn.");
  return messages.slice(boundary).flatMap(({ info, parts }) => {
    if (info.role === "user" || info.summary) return [];
    return [{ type: "assistant", message: { content: parts.filter((part) => part.type === "text") } }];
  }).map((message) => JSON.stringify(message)).join("\n");
}

/** Run the gate with an already-flushed snapshot, cleaned up even on cancellation. */
async function checkTurn(context, state, sessionID, messages) {
  const turnID = state.turnID;
  const signal = state.controller.signal;
  const temporary = await mkdtemp(join(tmpdir(), "opencode-stopgate-"));
  try {
    if (signal.aborted) return undefined;
    const path = join(temporary, "transcript.jsonl");
    await writeFile(path, transcript(messages, turnID));
    return await runGate("stop-gate", { session_id: sessionID, transcript_path: path }, context.directory, signal);
  } finally {
    await rm(temporary, { recursive: true });
  }
}

/** Both the model and human receive the shared gate's verdict. */
async function deliverVerdict(context, state, delivery) {
  const { client } = context;
  const { sessionID, lastUser, verdict, revision, assistantID } = delivery;
  if (verdict.systemMessage) {
    try {
      await client.tui.showToast({ body: { title: "Stopgate", message: verdict.systemMessage, variant: "info", duration: 10000 }, throwOnError: true });
    } catch (error) {
      await reportFailure(client, error);
    }
  }
  if (state.closing || revision !== state.revision) return;
  if (verdict.decision === "block") {
    if (typeof verdict.reason !== "string" || !verdict.reason.trim()) throw new Error("claude-gate blocked without a reason. Check the gate's JSON protocol.");
    await client.session.promptAsync({
      path: { id: sessionID },
      body: {
        agent: lastUser.agent, model: lastUser.model, variant: lastUser.variant,
        parts: [{ type: "text", text: verdict.reason, synthetic: true, metadata: { stopgateSource: assistantID } }],
      },
      throwOnError: true,
    });
    await confirmContinuation(context, state, delivery);
  } else if (verdict.decision !== undefined) {
    throw new Error(`claude-gate returned an unknown decision: ${verdict.decision}. Check the gate's JSON protocol.`);
  }
}

/** promptAsync acknowledges before saving; do not confuse acceptance with delivery. */
async function confirmContinuation(context, state, delivery) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (state.closing || state.revision !== delivery.revision) return;
    const response = await context.client.session.messages({ path: { id: delivery.sessionID }, throwOnError: true });
    if (response.data.some(({ info, parts }) => info.role === "user"
      && parts.some((part) => part.metadata?.stopgateSource === delivery.assistantID))) return;
    await new Promise((accept) => setTimeout(accept, 100));
  }
  throw new Error("OpenCode accepted the gate feedback but did not save it within five seconds. Check session.error in the OpenCode log before retrying.");
}

/** Aborted, failed, unfinished, and already-checked messages are not fresh Stops. */
async function onIdle(context, state, sessionID, revision) {
  if (state.closing || revision !== state.revision) return;
  const response = await context.client.session.messages({ path: { id: sessionID }, throwOnError: true });
  if (state.closing || revision !== state.revision) return;
  const messages = response.data;
  const latest = messages.at(-1)?.info;
  if (!latest || latest.role !== "assistant" || latest.error || !latest.time.completed) return;
  if (!latest.finish || ["tool-calls", "unknown"].includes(latest.finish) || latest.id === state.checked) return;
  const lastUser = messages.findLast(({ info }) => info.role === "user")?.info;
  if (!lastUser) throw new Error("OpenCode completed a turn without a user message. Check the session transcript before retrying.");
  state.controller = new AbortController();
  try {
    const verdict = await checkTurn(context, state, sessionID, messages);
    if (verdict && revision === state.revision && !state.closing) {
      await deliverVerdict(context, state, { sessionID, lastUser, verdict, revision, assistantID: latest.id });
      state.checked = latest.id;
    }
  } finally {
    state.controller = undefined;
  }
}

/** OpenCode does not await event hooks, so report rejected work explicitly. */
async function reportFailure(client, error) {
  const message = `Stopgate did not check this turn: ${error.message}. Check the OpenCode log and claude-gate installation; for reviewer login failures, run claude once in this instance.`;
  const reports = await Promise.allSettled([
    client.app.log({ body: { service: "stopgate", level: "error", message }, throwOnError: true }),
    client.tui.showToast({ body: { title: "Stopgate failed", message, variant: "error", duration: 20000 }, throwOnError: true }),
  ]);
  for (const report of reports) {
    if (report.status === "rejected") console.error(message, report.reason);
  }
}

// Decision: adapt OpenCode's idle event to the existing gate binary instead of
// duplicating review policy in JS. OpenCode 1.18.30 has no blocking Stop hook;
// promptAsync resumes a rejected turn using the same agent/model. Gate prompts
// are synthetic, so they neither reset phase counters nor erase earlier claims.
export default async function Stopgate(context) {
  const sessions = new Map();
  let closing = false;
  return {
    "chat.message": async (input, output) => {
      if (closing || !realPrompt(output.parts)) return;
      const root = await rootSession(context.client, input.sessionID);
      if (closing || root !== input.sessionID) return;
      const state = sessionState(sessions, root);
      state.revision += 1;
      state.turnID = output.message.id;
      state.controller?.abort();
      await enqueue(state, () => runSessionGate(context, state, "reset", { session_id: root }));
    },
    "tool.execute.after": async (input, output) => {
      if (closing) return;
      const edits = recordedEdits(input, output, context.directory);
      if (edits.length === 0) return;
      const root = await rootSession(context.client, input.sessionID);
      if (closing) return;
      const state = sessionState(sessions, root);
      await enqueue(state, async () => {
        for (const edit of edits) await runSessionGate(context, state, "record", { session_id: root, ...edit });
      });
    },
    event: async ({ event }) => {
      if (closing || event.type !== "session.idle") return;
      try {
        const sessionID = event.properties.sessionID;
        if (await rootSession(context.client, sessionID) !== sessionID) return;
        if (closing) return;
        const state = sessionState(sessions, sessionID);
        const revision = state.revision;
        await enqueue(state, () => onIdle(context, state, sessionID, revision));
      } catch (error) {
        await reportFailure(context.client, error);
      }
    },
    dispose: async () => {
      closing = true;
      for (const state of sessions.values()) {
        state.closing = true;
        state.revision += 1;
        state.controller?.abort();
      }
      await Promise.all([...sessions.values()].map((state) => state.pending));
    },
  };
}
