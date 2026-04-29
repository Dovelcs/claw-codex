#!/usr/bin/env node
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import WebSocket, { WebSocketServer } from "ws";

function defaultSocketPath() {
  const base = process.env.XDG_RUNTIME_DIR || path.join(os.tmpdir(), `codex-bridge-${process.getuid?.() ?? "user"}`);
  return path.join(base, "app-server.sock");
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function sameRealPath(a, b) {
  try {
    return fs.realpathSync(a) === fs.realpathSync(b);
  } catch {
    return false;
  }
}

function findRealCodex() {
  if (process.env.CODEX_BRIDGE_REAL_CODEX) {
    return process.env.CODEX_BRIDGE_REAL_CODEX;
  }

  const vscodeRoot = path.join(os.homedir(), ".vscode-server", "extensions");
  if (fs.existsSync(vscodeRoot)) {
    const extensionDirs = fs.readdirSync(vscodeRoot)
      .filter((name) => name.startsWith("openai.chatgpt-"))
      .sort()
      .reverse();
    for (const dir of extensionDirs) {
      const bundled = path.join(vscodeRoot, dir, "bin", "linux-x86_64", "codex");
      if (isExecutable(bundled)) {
        return bundled;
      }
    }
  }

  const self = process.argv[1] ? path.resolve(process.argv[1]) : "";
  const pathEntries = (process.env.PATH || "").split(path.delimiter).filter(Boolean);
  for (const entry of pathEntries) {
    const candidate = path.join(entry, "codex");
    if (isExecutable(candidate) && !sameRealPath(candidate, self)) {
      return candidate;
    }
  }

  return "codex";
}

function hasListenArg(args) {
  return args.some((arg, index) => arg === "--listen" || arg.startsWith("--listen=") || args[index - 1] === "--listen");
}

function socketAcceptsConnections(socketPath) {
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    const done = (ok) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(300, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

function parseJsonLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasId(message) {
  return isObject(message) && Object.prototype.hasOwnProperty.call(message, "id") && message.id !== undefined && message.id !== null;
}

function methodOf(message) {
  return isObject(message) && typeof message.method === "string" ? message.method : undefined;
}

function logFilePath() {
  const logDir = path.join(os.homedir(), ".codex-bridge");
  fs.mkdirSync(logDir, { recursive: true });
  return path.join(logDir, "vscode-stdio-relay.log");
}

function makeLogger() {
  const file = logFilePath();
  return (message) => {
    const line = `${new Date().toISOString()} ${message}\n`;
    try {
      fs.appendFileSync(file, line);
    } catch {
      // Logging must never break the VS Code stdio protocol.
    }
    process.stderr.write(line);
  };
}

function writeJsonLine(stream, payload) {
  stream.write(`${JSON.stringify(payload)}\n`);
}

class AppServerStdioRelay {
  constructor({ realCodex, args, socketPath }) {
    this.realCodex = realCodex;
    this.args = args;
    this.socketPath = socketPath;
    this.log = makeLogger();
    this.nextClientId = 1;
    this.nextRemoteRequest = 1;
    this.remotePending = new Map();
    this.remoteQueue = [];
    this.remoteClients = new Map();
    this.primaryInitializeId = undefined;
    this.primaryInitialized = false;
    this.child = undefined;
    this.httpServer = undefined;
    this.wss = undefined;
  }

  async run() {
    await this.startSocket();
    this.startChild();
    this.pipePrimaryInput();
    await this.waitForChildExit();
  }

  async startSocket() {
    fs.mkdirSync(path.dirname(this.socketPath), { recursive: true });
    if (fs.existsSync(this.socketPath)) {
      if (await socketAcceptsConnections(this.socketPath)) {
        throw new Error(`app-server relay socket is already active: ${this.socketPath}`);
      }
      fs.unlinkSync(this.socketPath);
    }

    this.httpServer = http.createServer();
    this.wss = new WebSocketServer({ server: this.httpServer });
    this.wss.on("connection", (ws) => this.handleRemoteConnection(ws));

    await new Promise((resolve, reject) => {
      const cleanup = () => {
        this.httpServer?.off("listening", onListening);
        this.httpServer?.off("error", onError);
      };
      const onListening = () => {
        cleanup();
        try {
          fs.chmodSync(this.socketPath, 0o600);
        } catch {
          // Best effort only.
        }
        this.log(`relay listening unix://${this.socketPath}`);
        resolve();
      };
      const onError = (error) => {
        cleanup();
        reject(error);
      };
      this.httpServer?.once("listening", onListening);
      this.httpServer?.once("error", onError);
      this.httpServer?.listen(this.socketPath);
    });
  }

  startChild() {
    this.log(`starting real codex: ${this.realCodex} ${this.args.join(" ")}`);
    this.child = spawn(this.realCodex, this.args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        CODEX_BRIDGE_WRAPPED: "1",
        CODEX_BRIDGE_RELAY_SOCKET: this.socketPath
      }
    });

    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");

    const stdout = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    stdout.on("line", (line) => this.handleChildStdoutLine(line));

    const stderr = readline.createInterface({ input: this.child.stderr, crlfDelay: Infinity });
    stderr.on("line", (line) => {
      if (line.trim()) {
        this.log(`child stderr: ${line}`);
      }
    });

    this.child.on("error", (error) => {
      this.log(`child error: ${error.message}`);
      this.failRemotePending(`codex app-server error: ${error.message}`);
    });
  }

  pipePrimaryInput() {
    process.stdin.setEncoding("utf8");
    const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
    input.on("line", (line) => this.handlePrimaryLine(line));
    input.on("close", () => {
      this.log("primary stdin closed");
      this.child?.stdin.end();
    });
  }

  waitForChildExit() {
    return new Promise((resolve) => {
      this.child?.on("exit", (code, signal) => {
        this.log(`child exited code=${code ?? "null"} signal=${signal ?? "none"}`);
        this.failRemotePending(`codex app-server exited code=${code ?? "null"} signal=${signal ?? "none"}`);
        this.closeRemoteClients();
        this.wss?.close();
        this.httpServer?.close();
        try {
          fs.unlinkSync(this.socketPath);
        } catch {
          // Ignore stale cleanup failures.
        }
        if (signal) {
          process.kill(process.pid, signal);
          return;
        }
        process.exitCode = code ?? 0;
        resolve();
      });
    });
  }

  writeToChild(payload) {
    if (!this.child || !this.child.stdin.writable) {
      throw new Error("real codex app-server stdin is not writable");
    }
    writeJsonLine(this.child.stdin, payload);
  }

  handlePrimaryLine(line) {
    const message = parseJsonLine(line);
    if (!message) {
      if (line.trim()) {
        this.log(`primary non-json line ignored: ${line.slice(0, 200)}`);
      }
      return;
    }

    const method = methodOf(message);
    if (hasId(message) && method === "initialize") {
      this.primaryInitializeId = message.id;
    }

    try {
      this.writeToChild(message);
    } catch (error) {
      this.log(`failed to forward primary message: ${error.message}`);
      throw error;
    }
  }

  handleChildStdoutLine(line) {
    const message = parseJsonLine(line);
    if (!message) {
      if (line.trim()) {
        this.log(`child non-json line: ${line.slice(0, 500)}`);
      }
      return;
    }

    if (hasId(message) && this.remotePending.has(message.id)) {
      this.forwardRemoteResponse(message);
      return;
    }

    if (hasId(message) && this.primaryInitializeId !== undefined && message.id === this.primaryInitializeId) {
      this.primaryInitialized = true;
      writeJsonLine(process.stdout, message);
      this.flushRemoteQueue();
      return;
    }

    writeJsonLine(process.stdout, message);

    if (!hasId(message) && methodOf(message)) {
      this.broadcastRemote(message);
    }
  }

  handleRemoteConnection(ws) {
    const clientId = `remote-${this.nextClientId++}`;
    this.remoteClients.set(clientId, ws);
    this.log(`remote connected ${clientId}`);

    ws.on("message", (data) => {
      const text = Buffer.isBuffer(data) ? data.toString("utf8") : String(data);
      this.handleRemoteMessage(clientId, ws, text);
    });
    ws.on("close", () => {
      this.remoteClients.delete(clientId);
      this.dropRemotePendingFor(ws);
      this.log(`remote closed ${clientId}`);
    });
    ws.on("error", (error) => {
      this.log(`remote error ${clientId}: ${error.message}`);
    });
  }

  handleRemoteMessage(clientId, ws, text) {
    const message = parseJsonLine(text);
    if (!message) {
      this.sendRemoteError(ws, undefined, -32700, "Parse error");
      return;
    }

    const method = methodOf(message);
    if (method === "initialize" && hasId(message)) {
      this.sendRemote(ws, {
        jsonrpc: "2.0",
        id: message.id,
        result: {
          serverInfo: {
            name: "codex-bridge-stdio-relay",
            version: "0.1.0"
          },
          capabilities: {
            proxiedAppServer: true
          }
        }
      });
      return;
    }

    if (method === "initialized" && !hasId(message)) {
      return;
    }

    if (!method) {
      this.sendRemoteError(ws, hasId(message) ? message.id : undefined, -32600, "Invalid JSON-RPC message");
      return;
    }

    if (!hasId(message)) {
      try {
        this.writeToChild(message);
      } catch (error) {
        this.sendRemoteError(ws, undefined, -32000, error.message);
      }
      return;
    }

    const relayId = `bridge:${clientId}:${this.nextRemoteRequest++}`;
    const relayed = {
      ...message,
      id: relayId
    };
    this.remotePending.set(relayId, {
      ws,
      originalId: message.id
    });

    if (!this.primaryInitialized) {
      this.remoteQueue.push(relayed);
      return;
    }
    this.forwardRemoteRequest(relayed, ws);
  }

  forwardRemoteRequest(payload, ws) {
    try {
      this.writeToChild(payload);
    } catch (error) {
      this.remotePending.delete(payload.id);
      this.sendRemoteError(ws, payload.id, -32000, error.message);
    }
  }

  flushRemoteQueue() {
    const queued = this.remoteQueue.splice(0);
    for (const payload of queued) {
      const pending = this.remotePending.get(payload.id);
      if (!pending) continue;
      this.forwardRemoteRequest(payload, pending.ws);
    }
    if (queued.length) {
      this.log(`flushed ${queued.length} queued remote request(s)`);
    }
  }

  forwardRemoteResponse(message) {
    const pending = this.remotePending.get(message.id);
    if (!pending) return;
    this.remotePending.delete(message.id);
    this.sendRemote(pending.ws, {
      ...message,
      id: pending.originalId
    });
  }

  broadcastRemote(message) {
    const text = JSON.stringify(message);
    for (const ws of this.remoteClients.values()) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(text);
      }
    }
  }

  sendRemote(ws, payload) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(payload));
    }
  }

  sendRemoteError(ws, id, code, message) {
    this.sendRemote(ws, {
      jsonrpc: "2.0",
      id: id ?? null,
      error: {
        code,
        message
      }
    });
  }

  dropRemotePendingFor(ws) {
    for (const [id, pending] of this.remotePending.entries()) {
      if (pending.ws === ws) {
        this.remotePending.delete(id);
      }
    }
    this.remoteQueue = this.remoteQueue.filter((payload) => this.remotePending.has(payload.id));
  }

  failRemotePending(message) {
    for (const [id, pending] of this.remotePending.entries()) {
      this.sendRemote(pending.ws, {
        jsonrpc: "2.0",
        id: pending.originalId,
        error: {
          code: -32000,
          message
        }
      });
      this.remotePending.delete(id);
    }
    this.remoteQueue = [];
  }

  closeRemoteClients() {
    for (const ws of this.remoteClients.values()) {
      try {
        ws.close();
      } catch {
        // Ignore.
      }
    }
    this.remoteClients.clear();
  }
}

function spawnPassthrough(realCodex, args) {
  const child = spawn(realCodex, args, {
    stdio: "inherit",
    env: {
      ...process.env,
      CODEX_BRIDGE_WRAPPED: "1"
    }
  });

  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(signal, () => {
      child.kill(signal);
    });
  }

  child.on("exit", (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code ?? 0);
  });

  child.on("error", (error) => {
    console.error(`failed to start real codex executable "${realCodex}": ${error.message}`);
    process.exit(127);
  });
}

const realCodex = findRealCodex();
const args = process.argv.slice(2);

if (
  process.env.CODEX_BRIDGE_DISABLE_WRAPPER !== "1" &&
  args[0] === "app-server" &&
  !hasListenArg(args)
) {
  const socketPath = process.env.CODEX_BRIDGE_APP_SERVER_SOCK || defaultSocketPath();
  const relay = new AppServerStdioRelay({ realCodex, args, socketPath });

  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(signal, () => {
      relay.child?.kill(signal);
    });
  }

  relay.run().catch((error) => {
    console.error(`codex app-server relay failed: ${error.message}`);
    process.exit(1);
  });
} else {
  spawnPassthrough(realCodex, args);
}
