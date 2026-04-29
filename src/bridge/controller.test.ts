import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BridgeController } from "./controller.js";
import { StateStore } from "./state.js";

test("sendToActiveThread steers guidance messages through VS Code IPC", async () => {
  const statePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "codex-bridge-state-")), "state.json");
  const controller = new BridgeController({ state: new StateStore(statePath), vscodeIpc: false });
  controller.state.setActiveThread("thread-1", controller.profile);
  const calls: string[] = [];
  (controller as unknown as {
    vscodeIpc: {
      steerTurn: (threadId: string, text: string) => Promise<unknown>;
      startTurn: (threadId: string, text: string) => Promise<unknown>;
      close: () => void;
    };
  }).vscodeIpc = {
    async steerTurn(threadId: string, text: string) {
      calls.push(`steer:${threadId}:${text}`);
      return { mode: "steer", transport: "vscode-ipc", turnId: "turn-steer" };
    },
    async startTurn(threadId: string, text: string) {
      calls.push(`start:${threadId}:${text}`);
      return { mode: "start", transport: "vscode-ipc", turnId: "turn-start" };
    },
    close() {}
  };

  const result = await controller.sendToActiveThread("补充方向", { guidance: true });

  assert.equal(result.mode, "steer");
  assert.deepEqual(calls, ["steer:thread-1:补充方向"]);
  controller.close();
});

test("sendToActiveThread falls back to start when guidance steering is unavailable", async () => {
  const statePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "codex-bridge-state-")), "state.json");
  const controller = new BridgeController({ state: new StateStore(statePath), vscodeIpc: false });
  controller.state.setActiveThread("thread-1", controller.profile);
  const calls: string[] = [];
  (controller as unknown as {
    vscodeIpc: {
      steerTurn: (threadId: string, text: string) => Promise<unknown>;
      startTurn: (threadId: string, text: string) => Promise<unknown>;
      close: () => void;
    };
  }).vscodeIpc = {
    async steerTurn(threadId: string, text: string) {
      calls.push(`steer:${threadId}:${text}`);
      throw new Error("no active turn");
    },
    async startTurn(threadId: string, text: string) {
      calls.push(`start:${threadId}:${text}`);
      return { mode: "start", transport: "vscode-ipc", turnId: "turn-start" };
    },
    close() {}
  };

  const result = await controller.sendToActiveThread("补充方向", { guidance: true });

  assert.equal(result.mode, "start");
  assert.deepEqual(calls, ["steer:thread-1:补充方向", "start:thread-1:补充方向"]);
  controller.close();
});
