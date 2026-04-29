import test from "node:test";
import assert from "node:assert/strict";
import { normalizeRolloutLine } from "./rollout-monitor.js";

test("normalizeRolloutLine extracts user, final, and task completion events", () => {
  assert.deepEqual(normalizeRolloutLine(JSON.stringify({
    timestamp: "2026-04-29T09:00:00.000Z",
    type: "event_msg",
    payload: { type: "user_message", message: "测试" }
  }), "thread-1"), [{
    kind: "user_input",
    timestamp: "2026-04-29T09:00:00.000Z",
    threadId: "thread-1",
    role: "user",
    text: "测试"
  }]);

  assert.deepEqual(normalizeRolloutLine(JSON.stringify({
    timestamp: "2026-04-29T09:00:01.000Z",
    type: "response_item",
    payload: {
      type: "message",
      role: "assistant",
      phase: "final_answer",
      content: [{ type: "output_text", text: "收到。" }]
    }
  }), "thread-1"), [{
    kind: "final_answer",
    timestamp: "2026-04-29T09:00:01.000Z",
    threadId: "thread-1",
    role: "assistant",
    text: "收到。"
  }]);

  assert.deepEqual(normalizeRolloutLine(JSON.stringify({
    timestamp: "2026-04-29T09:00:02.000Z",
    type: "event_msg",
    payload: { type: "task_complete", turn_id: "turn-1" }
  }), "thread-1"), [{
    kind: "task_complete",
    timestamp: "2026-04-29T09:00:02.000Z",
    threadId: "thread-1",
    turnId: "turn-1"
  }]);
});
