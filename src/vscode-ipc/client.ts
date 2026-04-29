import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { extractTurnId, textInput } from "../appserver/client.js";
import type { StartOrSteerResult } from "../appserver/types.js";

export interface VscodeIpcClientOptions {
  socketPath?: string;
  requestTimeoutMs?: number;
  clientType?: string;
}

interface PendingRequest {
  method: string;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

const METHOD_VERSIONS: Record<string, number> = {
  initialize: 0,
  "thread-follower-start-turn": 1,
  "thread-follower-steer-turn": 1,
  "thread-follower-interrupt-turn": 1
};

export class VscodeIpcClient extends EventEmitter {
  private socket?: net.Socket;
  private buffer = Buffer.alloc(0);
  private clientId?: string;
  private readonly pending = new Map<string, PendingRequest>();
  private connectPromise?: Promise<void>;

  constructor(private readonly options: VscodeIpcClientOptions = {}) {
    super();
  }

  async startTurn(conversationId: string, text: string): Promise<StartOrSteerResult> {
    const response = await this.request("thread-follower-start-turn", {
      conversationId,
      turnStartParams: {
        input: [textInput(text)]
      }
    });
    return {
      mode: "start",
      transport: "vscode-ipc",
      response,
      turnId: extractTurnId(response)
    };
  }

  async steerTurn(conversationId: string, text: string, restoreMessage?: unknown, attachments?: unknown): Promise<StartOrSteerResult> {
    const response = await this.request("thread-follower-steer-turn", {
      conversationId,
      input: [textInput(text)],
      restoreMessage,
      attachments
    });
    return {
      mode: "steer",
      transport: "vscode-ipc",
      response,
      turnId: extractTurnId(response)
    };
  }

  async interruptTurn(conversationId: string): Promise<unknown> {
    return this.request("thread-follower-interrupt-turn", { conversationId });
  }

  async initialize(): Promise<string> {
    await this.connectSocket();
    if (this.clientId) {
      return this.clientId;
    }
    const result = await this.requestRaw("initialize", {
      clientType: this.options.clientType ?? "vscode"
    });
    const clientId = getString(result, "clientId");
    if (!clientId) {
      throw new Error("VS Code IPC initialize response did not include clientId");
    }
    this.clientId = clientId;
    return clientId;
  }

  async request(method: string, params?: unknown): Promise<unknown> {
    await this.initialize();
    return this.requestRaw(method, params);
  }

  close(): void {
    this.rejectAllPending(new Error("VS Code IPC client closed"));
    this.socket?.destroy();
    this.socket = undefined;
    this.connectPromise = undefined;
    this.clientId = undefined;
  }

  private async connectSocket(): Promise<void> {
    if (this.socket && !this.socket.destroyed) {
      return;
    }
    if (this.connectPromise) {
      return this.connectPromise;
    }

    const socketPath = this.options.socketPath ?? defaultVscodeIpcSocketPath();
    this.connectPromise = new Promise((resolve, reject) => {
      const socket = net.createConnection(socketPath);
      const fail = (error: Error) => {
        socket.removeAllListeners();
        socket.destroy();
        reject(new Error(`failed to connect VS Code IPC socket ${socketPath}: ${error.message}`));
      };

      socket.once("connect", () => {
        socket.removeListener("error", fail);
        this.socket = socket;
        socket.on("data", (chunk) => this.onData(chunk));
        socket.on("error", (error) => this.emit("transportError", error));
        socket.on("close", () => {
          this.rejectAllPending(new Error("VS Code IPC socket closed"));
          this.socket = undefined;
          this.connectPromise = undefined;
          this.clientId = undefined;
        });
        resolve();
      });
      socket.once("error", fail);
    });

    return this.connectPromise;
  }

  private async requestRaw(method: string, params?: unknown): Promise<unknown> {
    await this.connectSocket();
    const requestId = randomUUID();
    const message: Record<string, unknown> = {
      type: "request",
      requestId,
      version: METHOD_VERSIONS[method] ?? 1,
      method,
      params
    };
    if (this.clientId) {
      message.sourceClientId = this.clientId;
    }

    const timeoutMs = this.options.requestTimeoutMs ?? 20_000;
    const response = new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`VS Code IPC request timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(requestId, { method, resolve, reject, timer });
    });
    this.writeMessage(message);
    return response;
  }

  private onData(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32LE(0);
      if (this.buffer.length < 4 + length) {
        return;
      }
      const body = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.subarray(4 + length);
      try {
        this.handleMessage(JSON.parse(body.toString("utf8")));
      } catch (error) {
        this.emit("protocolError", error);
      }
    }
  }

  private handleMessage(message: unknown): void {
    if (!message || typeof message !== "object") {
      return;
    }
    const record = message as Record<string, unknown>;
    const type = getString(record, "type");
    if (type === "response") {
      this.handleResponse(record);
      return;
    }
    if (type === "client-discovery-request") {
      this.writeMessage({
        type: "client-discovery-response",
        requestId: record.requestId,
        sourceClientId: this.clientId,
        targetClientId: record.sourceClientId,
        method: record.method,
        canHandle: false
      });
      return;
    }
    if (type === "request") {
      this.writeMessage({
        type: "response",
        requestId: record.requestId,
        method: record.method,
        handledByClientId: this.clientId,
        resultType: "failure",
        error: {
          message: `external bridge client has no handler for ${String(record.method ?? "request")}`
        }
      });
      return;
    }
    if (type === "broadcast") {
      this.emit("broadcast", record);
      return;
    }
    this.emit("message", record);
  }

  private handleResponse(record: Record<string, unknown>): void {
    const requestId = getString(record, "requestId");
    if (!requestId) {
      return;
    }
    const pending = this.pending.get(requestId);
    if (!pending) {
      return;
    }
    clearTimeout(pending.timer);
    this.pending.delete(requestId);

    if (record.resultType === "success" || record.resultType === undefined && !record.error) {
      pending.resolve(record.result);
      return;
    }

    const message = getNestedString(record.error, "message")
      ?? getString(record, "message")
      ?? `VS Code IPC request failed: ${pending.method}`;
    const error = new Error(message);
    (error as Error & { data?: unknown }).data = record;
    pending.reject(error);
  }

  private writeMessage(message: Record<string, unknown>): void {
    if (!this.socket || this.socket.destroyed) {
      throw new Error("VS Code IPC socket is not connected");
    }
    const body = Buffer.from(JSON.stringify(message), "utf8");
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length, 0);
    this.socket.write(Buffer.concat([header, body]));
  }

  private rejectAllPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

export function defaultVscodeIpcSocketPath(): string {
  return path.join(os.tmpdir(), "codex-ipc", `ipc-${process.getuid?.() ?? "user"}.sock`);
}

function getString(value: unknown, key: string): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  const candidate = (value as Record<string, unknown>)[key];
  return typeof candidate === "string" ? candidate : undefined;
}

function getNestedString(value: unknown, key: string): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  return getString(value, key);
}
