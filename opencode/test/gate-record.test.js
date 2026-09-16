import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

test("the real gate records deleted-file patches, filters large/binary patches, and resets", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "gate-record-test-"));
  const gate = process.env.CLAUDE_GATE_TEST_BINARY ?? "claude-gate";
  const options = { encoding: "utf8", env: { ...process.env, TMPDIR: temporary, CLAUDE_SKIP_RULE_CHECK: "0" } };
  try {
    for (const [file, patch] of [["deleted.hs", "@@ -1 +0 @@\n-old\n"], ["large.hs", "x".repeat(50001)], ["binary.hs", "\0"], ["image.png", "-data"]]) {
      const result = spawnSync(gate, ["record"], { ...options, input: JSON.stringify({
        session_id: "test", tool_name: "ApplyPatch", tool_input: { file_path: join(temporary, file), patch },
      }) });
      assert.equal(result.status, 0, result.error?.message ?? result.stderr);
    }
    const path = join(temporary, "claude-turn-state/test/edits.jsonl");
    const edits = (await readFile(path, "utf8")).trim().split("\n").map(JSON.parse);
    assert.deepEqual(edits, [{ tool: "ApplyPatch", file_path: join(temporary, "deleted.hs"), patch: "@@ -1 +0 @@\n-old\n" }]);
    const reset = spawnSync(gate, ["reset"], { ...options, input: '{"session_id":"test"}' });
    assert.equal(reset.status, 0, reset.stderr);
    await assert.rejects(readFile(path), { code: "ENOENT" });
  } finally {
    await rm(temporary, { recursive: true });
  }
});

test("OpenCode reviewers remain in the cancellable gate process group", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "gate-reviewer-test-"));
  try {
    const fixture = `#!${process.execPath}
const fs = require('node:fs');
fs.readFileSync(0);
fs.writeFileSync(${JSON.stringify(join(temporary, "arguments"))}, JSON.stringify(process.argv.slice(2)));
process.stdout.write('OK');
`;
    await writeFile(join(temporary, "timeout"), fixture, { mode: 0o755 });
    await writeFile(join(temporary, "claude"), fixture, { mode: 0o755 });
    const transcript = join(temporary, "transcript.jsonl");
    await writeFile(transcript, JSON.stringify({ type: "assistant", message: { content: "A claim to critique." } }));
    const result = spawnSync(process.env.CLAUDE_GATE_TEST_BINARY ?? "claude-gate", ["stop-gate"], {
      encoding: "utf8", cwd: temporary,
      env: { ...process.env, PATH: `${temporary}:${process.env.PATH}`, TMPDIR: temporary,
        CLAUDE_SKIP_HOURS_CHECK: "1", CLAUDE_SKIP_DUMBIFY: "1", CLAUDE_SKIP_RULE_CHECK: "1",
        CLAUDE_SKIP_CRITIQUE: "0", CLAUDE_GATE_SHARED_PROCESS_GROUP: "1" },
      input: JSON.stringify({ session_id: "test", transcript_path: transcript }),
    });
    assert.equal(result.status, 0, result.error?.message ?? result.stderr);
    assert.equal(JSON.parse(await readFile(join(temporary, "arguments"), "utf8"))[0], "--foreground");
    assert.match(JSON.parse(result.stdout).systemMessage, /critique/);
  } finally {
    await rm(temporary, { recursive: true });
  }
});
