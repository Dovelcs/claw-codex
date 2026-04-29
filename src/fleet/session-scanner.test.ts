import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { CodexSessionScanner, mergeFleetSessions } from "./session-scanner.js";

test("CodexSessionScanner reads session_meta jsonl when sqlite is unavailable", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-session-scan-"));
  const sessionDir = path.join(dir, "sessions", "2026", "04", "28");
  fs.mkdirSync(sessionDir, { recursive: true });
  fs.writeFileSync(path.join(sessionDir, "rollout-test.jsonl"), [
    JSON.stringify({
      type: "session_meta",
      payload: {
        id: "thread-jsonl",
        cwd: "/repo/project",
        source: "vscode",
        timestamp: "2026-04-28T12:00:00.000Z"
      }
    }),
    JSON.stringify({
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "实现历史会话 fallback" }]
      }
    })
  ].join("\n"));

  const scanner = new CodexSessionScanner({ codexHome: dir, sqliteBin: "/missing/sqlite3" });
  const sessions = await scanner.scan();

  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].id, "thread-jsonl");
  assert.equal(sessions[0].source, "vscode");
  assert.equal(sessions[0].cwd, "/repo/project");
  assert.equal(sessions[0].title, "实现历史会话 fallback");
  assert.match(sessions[0].rolloutPath ?? "", /rollout-test\.jsonl$/);
});

test("mergeFleetSessions keeps app-server records and fills rollout path from JSONL fallback", () => {
  const merged = mergeFleetSessions([
    { id: "thread-1", source: "vscode", title: "live" }
  ], [
    { id: "thread-1", source: "vscode", title: "old", rolloutPath: "/tmp/rollout-1.jsonl" },
    { id: "thread-2", source: "vscode", title: "fallback" }
  ]);

  assert.deepEqual(merged.map((session) => [session.id, session.title, session.rolloutPath]), [
    ["thread-1", "live", "/tmp/rollout-1.jsonl"],
    ["thread-2", "fallback", undefined]
  ]);
});
