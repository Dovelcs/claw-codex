import test from "node:test";
import assert from "node:assert/strict";
import { extractActiveTurnId, extractStatus, isRunningStatus } from "./thread-utils.js";

test("extractStatus handles flat and nested status shapes", () => {
  assert.equal(extractStatus({ status: "running" }), "running");
  assert.equal(extractStatus({ status: { type: "idle" } }), "idle");
});

test("extractActiveTurnId finds explicit and running turn ids", () => {
  assert.equal(extractActiveTurnId({ activeTurnId: "turn-1" }), "turn-1");
  assert.equal(extractActiveTurnId({ turns: [{ id: "turn-old", status: "completed" }, { turnId: "turn-run", status: "running" }] }), "turn-run");
});

test("isRunningStatus recognizes active app-server states", () => {
  assert.equal(isRunningStatus("running"), true);
  assert.equal(isRunningStatus("active"), true);
  assert.equal(isRunningStatus("idle"), false);
});
