import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { scanSessionFiles } from "./session-metadata-scan.mjs";

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "pilish-metadata-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

test("streams BOM/CRLF JSONL and preserves picker metadata semantics", async (t) => {
  const root = await fixture(t);
  const nested = join(root, "nested", "session.jsonl");
  await mkdir(join(root, "nested"));
  const lines = [
    "",
    JSON.stringify({ type: "session", id: "s1", cwd: "/tmp/雪" }),
    JSON.stringify({
      type: "message",
      message: { role: "assistant", content: [{ type: "text", text: "intro" }] },
    }),
    '{"type":"message","message":',
    JSON.stringify({ type: "session_info", name: "  old name  " }),
    JSON.stringify({
      type: "message",
      message: { role: "user", content: "first\nuser 雪" },
    }),
    JSON.stringify({
      type: "message",
      message: { role: "toolResult", content: [{ type: "text", text: "tool" }] },
    }),
    JSON.stringify({ type: "session_info", name: " \t " }),
  ];
  await writeFile(nested, "\uFEFF" + lines.join("\r\n") + "\r\n", "utf8");

  const [row] = await scanSessionFiles([nested]);
  assert.equal(row.path, nested);
  assert.equal(row.valid, true);
  assert.equal(row.stable, true);
  assert.equal(row.cwd, "/tmp/雪");
  assert.equal(row.name, "old name", "the first session_info name wins");
  assert.equal(row.firstMessage, "first\nuser 雪");
  assert.equal("messageCount" in row, false);
});

test("uses the first parsed non-user message as fallback within the five-line budget", async (t) => {
  const root = await fixture(t);
  const file = join(root, "fallback.jsonl");
  const messages = Array.from({ length: 6 }, (_, index) => ({
    type: "message",
    message: {
      role: index === 5 ? "user" : "assistant",
      content: index === 0
        ? [
            { type: "text", text: "message 1" },
            { type: "text", text: "continued" },
          ]
        : "message " + (index + 1),
    },
  }));
  await writeFile(
    file,
    [
      JSON.stringify({ type: "session", cwd: "/tmp" }),
      ...messages.map(JSON.stringify),
    ].join("\n"),
    "utf8",
  );

  const [row] = await scanSessionFiles([file]);
  assert.equal(row.firstMessage, "message 1 continued");
  assert.equal("messageCount" in row, false);
});

test("stops at the metadata prefix limit when the name is absent", async (t) => {
  const root = await fixture(t);
  const file = join(root, "late-name.jsonl");
  await writeFile(
    file,
    [
      JSON.stringify({ type: "session", cwd: "/tmp" }),
      JSON.stringify({ type: "message", message: { role: "user", content: "title" } }),
      JSON.stringify({ type: "custom", data: "x".repeat(20 * 1024) }),
      JSON.stringify({ type: "session_info", name: "too late" }),
    ].join("\n"),
    "utf8",
  );

  const [row] = await scanSessionFiles([file]);
  assert.equal(row.firstMessage, "title");
  assert.equal(row.name, null);
  assert.equal("messageCount" in row, false);
});

test("rejects files without a session header and validates the manifest", async (t) => {
  const root = await fixture(t);
  const invalid = join(root, "invalid.jsonl");
  await writeFile(invalid, '{"type":"message"}\n', "utf8");

  const [row] = await scanSessionFiles([invalid]);
  assert.deepEqual(
    { valid: row.valid, stable: row.stable },
    { valid: false, stable: true },
  );

  const emptyCwd = join(root, "empty-cwd.jsonl");
  await writeFile(emptyCwd, JSON.stringify({ type: "session", cwd: "" }), "utf8");
  const [emptyCwdRow] = await scanSessionFiles([emptyCwd]);
  assert.equal(emptyCwdRow.cwd, null);

  const renamed = join(root, "renamed.jsonl");
  await writeFile(
    renamed,
    [
      JSON.stringify({ type: "session" }),
      JSON.stringify({ type: "session_info", name: "old" }),
      JSON.stringify({ type: "session_info", name: "  latest name  " }),
    ].join("\n"),
    "utf8",
  );
  const [renamedRow] = await scanSessionFiles([renamed]);
  assert.equal(renamedRow.name, "old", "later session_info updates are ignored");
  await assert.rejects(scanSessionFiles([42]), TypeError);
});
