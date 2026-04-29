import test from "node:test";
import assert from "node:assert/strict";
import { shouldMirrorFeishuBinding, shouldUseVscodeIpcForSession, threadToFleetSession, workerAppServerOptions } from "./agent.js";

test("threadToFleetSession exposes stable public fields", () => {
  assert.deepEqual(threadToFleetSession({
    id: "019dd3d6-a736-7aa3-bd8c",
    source: "vscode",
    title: "设计 codex-bridge 消息链路",
    cwd: "/home/donovan/samba/codex-server",
    rolloutPath: "/tmp/rollout.jsonl",
    updatedAt: 1
  }), {
    id: "019dd3d6-a736-7aa3-bd8c",
    source: "vscode",
    title: "设计 codex-bridge 消息链路",
    cwd: "/home/donovan/samba/codex-server",
    rolloutPath: "/tmp/rollout.jsonl"
  });
});

test("shouldUseVscodeIpcForSession only sends live messages to VS Code sessions", () => {
  assert.equal(shouldUseVscodeIpcForSession(undefined), true);
  assert.equal(shouldUseVscodeIpcForSession({
    id: "vscode-thread",
    source: "vscode",
    title: "live",
    cwd: "/work"
  }), true);
  assert.equal(shouldUseVscodeIpcForSession({
    id: "cli-thread",
    source: "cli",
    title: "history",
    cwd: "/work"
  }), false);
  assert.equal(shouldUseVscodeIpcForSession({
    id: "exec-thread",
    source: "exec",
    title: "headless",
    cwd: "/work"
  }), false);
});

test("workerAppServerOptions pins explicit socket ahead of ambient app-server URL", () => {
  assert.equal(workerAppServerOptions({}), undefined);
  assert.deepEqual(workerAppServerOptions({ appServerSocketPath: "/tmp/codex.sock" }), {
    appServerUrl: "unix:///tmp/codex.sock",
    socketPath: "/tmp/codex.sock"
  });
  assert.deepEqual(workerAppServerOptions({ appServerUrl: "ws://127.0.0.1:18999" }), {
    appServerUrl: "ws://127.0.0.1:18999",
    socketPath: undefined
  });
});

test("shouldMirrorFeishuBinding only accepts Feishu group chats", () => {
  assert.equal(shouldMirrorFeishuBinding({
    channel: "feishu",
    chat_id: "oc_group",
    session_id: "thread-1"
  }), true);
  assert.equal(shouldMirrorFeishuBinding({
    channel: "openclaw-feishu",
    chat_id: "oc_group",
    session_id: "thread-1"
  }), true);
  assert.equal(shouldMirrorFeishuBinding({
    channel: "feishu",
    chat_id: "ou_private",
    session_id: "thread-1"
  }), false);
  assert.equal(shouldMirrorFeishuBinding({
    channel: "feishu",
    chat_id: "default:direct:ou_private:thread:om_message",
    session_id: "thread-1"
  }), false);
  assert.equal(shouldMirrorFeishuBinding({
    channel: "openclaw-weixin",
    chat_id: "oc_group",
    session_id: "thread-1"
  }), false);
});
