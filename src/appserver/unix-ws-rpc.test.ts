import test from "node:test";
import assert from "node:assert/strict";
import { encodeClientFrame, tryDecodeFrame, unixSocketPathFromUrl } from "./unix-ws-rpc.js";

test("unixSocketPathFromUrl extracts absolute socket path", () => {
  assert.equal(unixSocketPathFromUrl("unix:///tmp/codex/app.sock"), "/tmp/codex/app.sock");
  assert.equal(unixSocketPathFromUrl("ws://127.0.0.1:18765"), undefined);
});

test("encodeClientFrame produces a masked text frame that can be decoded", () => {
  const frame = encodeClientFrame(0x1, Buffer.from("hello", "utf8"));
  assert.equal(frame[0], 0x81);
  assert.equal((frame[1] & 0x80) !== 0, true);

  const decoded = tryDecodeFrame(frame);
  assert.equal(decoded?.opcode, 0x1);
  assert.equal(decoded?.payload.toString("utf8"), "hello");
  assert.equal(decoded?.consumed, frame.length);
});
