import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { StateStore, resolveThreadSelector, shortThreadId } from "./state.js";

test("shortThreadId removes common thread prefix", () => {
  assert.equal(shortThreadId("thread-abcdef123456"), "abcdef123456");
  assert.equal(shortThreadId("019dd3d6-a736-7aa3"), "019dd3d6-a736");
});

test("resolveThreadSelector accepts exact and unique prefixes", () => {
  const threads = [
    { id: "thread-abcdef123456", shortId: "abcdef123456" },
    { id: "thread-fedcba654321", shortId: "fedcba654321" }
  ];
  assert.equal(resolveThreadSelector("abcdef123456", threads)?.id, "thread-abcdef123456");
  assert.equal(resolveThreadSelector("thread-fed", threads)?.id, "thread-fedcba654321");
  assert.equal(resolveThreadSelector("thread-", threads), undefined);
});

test("resolveThreadSelector rejects ambiguous short ids", () => {
  const threads = [
    { id: "thread-abcdef123456", shortId: "abcdef123456" },
    { id: "thread-uvwxyz123456", shortId: "abcdef123456" }
  ];
  assert.equal(resolveThreadSelector("abcdef123456", threads), undefined);
});

test("StateStore persists active thread binding", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-bridge-test-"));
  const store = new StateStore(path.join(dir, "state.json"));
  store.setActiveThread("thread-abc", "wechat-chat-1");
  assert.equal(store.activeThread("wechat-chat-1"), "thread-abc");
});
