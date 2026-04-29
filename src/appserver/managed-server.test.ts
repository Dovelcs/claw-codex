import test from "node:test";
import assert from "node:assert/strict";
import { shouldAutoStartAppServer } from "./managed-server.js";

test("shouldAutoStartAppServer defaults off", () => {
  assert.equal(shouldAutoStartAppServer(undefined), false);
  assert.equal(shouldAutoStartAppServer(""), false);
});

test("shouldAutoStartAppServer accepts common enabled values only", () => {
  assert.equal(shouldAutoStartAppServer("1"), true);
  assert.equal(shouldAutoStartAppServer("true"), true);
  assert.equal(shouldAutoStartAppServer("yes"), true);
  assert.equal(shouldAutoStartAppServer("on"), true);
  assert.equal(shouldAutoStartAppServer("0"), false);
  assert.equal(shouldAutoStartAppServer("false"), false);
  assert.equal(shouldAutoStartAppServer("off"), false);
});
