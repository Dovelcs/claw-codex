import test from "node:test";
import assert from "node:assert/strict";
import { normalizeAppServerUrl } from "./ws-rpc.js";

test("normalizeAppServerUrl maps unix URLs to websocket-over-unix options", () => {
  assert.deepEqual(normalizeAppServerUrl("unix:///tmp/codex/app.sock"), {
    url: "unix:///tmp/codex/app.sock",
    socketPath: "/tmp/codex/app.sock"
  });
});

test("normalizeAppServerUrl keeps tcp websocket URLs", () => {
  assert.deepEqual(normalizeAppServerUrl("ws://127.0.0.1:18765"), {
    url: "ws://127.0.0.1:18765"
  });
});
