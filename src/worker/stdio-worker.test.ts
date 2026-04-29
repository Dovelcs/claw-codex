import test from "node:test";
import assert from "node:assert/strict";
import { formatThreadList, publicThreadSummary } from "./core.js";
import { parseIncomingMessage } from "./stdio-worker.js";

test("parseIncomingMessage accepts manager JSON lines", () => {
  assert.deepEqual(parseIncomingMessage('{"chatId":"wx-1","text":"/vscode list"}'), {
    chatId: "wx-1",
    text: "/vscode list"
  });
});

test("formatThreadList uses short ids and names", () => {
  assert.equal(formatThreadList([{ id: "019dd3d6-a736", source: "vscode", name: "设计 codex-bridge 消息链路" }]), "019dd3d6-a736 设计 codex-bridge 消息链路");
});

test("publicThreadSummary does not expose full raw preview", () => {
  const summary = publicThreadSummary({
    id: "019dd3d6-a736",
    source: "vscode",
    preview: "x".repeat(200),
    cwd: "/tmp",
    updatedAt: 1
  });
  assert.equal(summary.title.length, 80);
  assert.equal("preview" in summary, false);
});
