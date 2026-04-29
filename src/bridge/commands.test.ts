import test from "node:test";
import assert from "node:assert/strict";
import { parseBridgeCommand } from "./commands.js";

test("parse vscode list/use/status commands", () => {
  assert.deepEqual(parseBridgeCommand("/vscode list"), { type: "vscode-list" });
  assert.deepEqual(parseBridgeCommand("/vscode use abc123"), { type: "vscode-use", selector: "abc123" });
  assert.deepEqual(parseBridgeCommand("vscode status"), { type: "vscode-status" });
});

test("parse stop and plain message commands", () => {
  assert.deepEqual(parseBridgeCommand("/stop"), { type: "stop" });
  assert.deepEqual(parseBridgeCommand("继续当前任务"), { type: "send", text: "继续当前任务" });
});
