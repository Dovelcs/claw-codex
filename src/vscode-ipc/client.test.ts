import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { VscodeIpcClient } from "./client.js";

test("VscodeIpcClient sends follower start-turn through length-prefixed IPC", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-ipc-test-"));
  const socketPath = path.join(dir, "ipc.sock");
  const received: Array<Record<string, unknown>> = [];

  const server = net.createServer((socket) => {
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4) {
        const length = buffer.readUInt32LE(0);
        if (buffer.length < 4 + length) {
          return;
        }
        const body = buffer.subarray(4, 4 + length);
        buffer = buffer.subarray(4 + length);
        const message = JSON.parse(body.toString("utf8")) as Record<string, unknown>;
        received.push(message);
        if (message.method === "initialize") {
          writeFrame(socket, {
            type: "response",
            requestId: message.requestId,
            method: "initialize",
            resultType: "success",
            handledByClientId: "owner-window",
            result: { clientId: "external-client" }
          });
        }
        if (message.method === "thread-follower-start-turn") {
          writeFrame(socket, {
            type: "response",
            requestId: message.requestId,
            method: "thread-follower-start-turn",
            resultType: "success",
            handledByClientId: "owner-window",
            result: { turnId: "turn-1" }
          });
        }
        if (message.method === "thread-follower-interrupt-turn") {
          writeFrame(socket, {
            type: "response",
            requestId: message.requestId,
            method: "thread-follower-interrupt-turn",
            resultType: "success",
            handledByClientId: "owner-window",
            result: { ok: true }
          });
        }
      }
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  t.after(() => {
    server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  const client = new VscodeIpcClient({ socketPath, requestTimeoutMs: 1000 });
  t.after(() => client.close());

  const result = await client.startTurn("thread-1", "测试");
  assert.equal(result.mode, "start");
  assert.equal(result.transport, "vscode-ipc");
  assert.equal(result.turnId, "turn-1");

  assert.equal(received[0]?.method, "initialize");
  assert.deepEqual(received[0]?.params, { clientType: "vscode" });
  assert.equal(received[1]?.method, "thread-follower-start-turn");
  assert.equal(received[1]?.sourceClientId, "external-client");
  assert.equal(received[1]?.version, 1);
  assert.deepEqual(received[1]?.params, {
    conversationId: "thread-1",
    turnStartParams: {
      input: [{ type: "text", text: "测试", text_elements: [] }]
    }
  });

  const interrupt = await client.interruptTurn("thread-1");
  assert.deepEqual(interrupt, { ok: true });
  assert.equal(received[2]?.method, "thread-follower-interrupt-turn");
  assert.equal(received[2]?.sourceClientId, "external-client");
  assert.equal(received[2]?.version, 1);
  assert.deepEqual(received[2]?.params, { conversationId: "thread-1" });
});

function writeFrame(socket: net.Socket, message: Record<string, unknown>): void {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([header, body]));
}
