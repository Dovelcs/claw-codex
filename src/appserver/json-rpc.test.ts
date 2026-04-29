import test from "node:test";
import assert from "node:assert/strict";
import { parseJsonLine, splitJsonLines } from "./json-rpc.js";

test("splitJsonLines keeps partial trailing JSON for the next chunk", () => {
  const first = splitJsonLines("", "{\"id\":1}\n{\"id\"");
  assert.deepEqual(first.lines, ["{\"id\":1}"]);
  assert.equal(first.rest, "{\"id\"");

  const second = splitJsonLines(first.rest, ":2}\n");
  assert.deepEqual(second.lines, ["{\"id\":2}"]);
  assert.equal(second.rest, "");
});

test("parseJsonLine ignores non-json proxy logs", () => {
  assert.deepEqual(parseJsonLine("{\"id\":1,\"result\":true}"), { id: 1, result: true });
  assert.equal(parseJsonLine("listening on unix socket"), undefined);
  assert.equal(parseJsonLine(""), undefined);
});
