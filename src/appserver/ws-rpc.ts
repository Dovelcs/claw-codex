import { EventEmitter } from "node:events";
import net from "node:net";
import WebSocket from "ws";
import type { JsonRpcNotification, JsonRpcRequest, JsonRpcResponse, RequestId } from "./types.js";
import { JsonRpcError } from "./json-rpc.js";

export interface WebSocketJsonRpcClientOptions {
  url: string;
  socketPath?: string;
  requestTimeoutMs?: number;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class WebSocketJsonRpcClient extends EventEmitter {
  private socket?: WebSocket;
  private openPromise?: Promise<void>;
  private nextId = 1;
  private pending = new Map<RequestId, PendingRequest>();
  private readonly timeoutMs: number;

  constructor(private readonly options: WebSocketJsonRpcClientOptions) {
    super();
    this.timeoutMs = options.requestTimeoutMs ?? 30_000;
  }

  async connect(): Promise<void> {
    if (this.socket?.readyState === WebSocket.OPEN) {
      return;
    }
    if (this.openPromise) {
      return this.openPromise;
    }

    const { url } = normalizeAppServerUrl(this.options.url);
    const socketPath = this.options.socketPath;
    this.socket = new WebSocket(url, {
      perMessageDeflate: false,
      ...(socketPath ? { createConnection: () => net.createConnection(socketPath) } : {})
    });
    this.socket.on("message", (data) => this.handleMessage(data));
    this.socket.on("error", (error) => {
      this.emit("transportError", error);
      this.failAll(error);
    });
    this.socket.on("close", (code, reason) => {
      this.emit("close", { code, reason: reason.toString("utf8") });
      this.failAll(new Error(`app-server websocket closed with code ${code}`));
      this.socket = undefined;
      this.openPromise = undefined;
    });

    this.openPromise = new Promise((resolve, reject) => {
      const onOpen = () => {
        cleanup();
        resolve();
      };
      const onError = (error: Error) => {
        cleanup();
        reject(error);
      };
      const cleanup = () => {
        this.socket?.off("open", onOpen);
        this.socket?.off("error", onError);
      };
      this.socket?.once("open", onOpen);
      this.socket?.once("error", onError);
    });

    return this.openPromise;
  }

  async request<T = unknown>(method: string, params?: unknown): Promise<T> {
    await this.connect();
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      throw new Error("app-server websocket is not open");
    }

    const id = this.nextId++;
    const payload: JsonRpcRequest = params === undefined ? { id, method } : { id, method, params };

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`app-server request timed out: ${method}`));
      }, this.timeoutMs);

      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timer
      });

      socket.send(JSON.stringify(payload), (error) => {
        if (error) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(error);
        }
      });
    });
  }

  close(): void {
    if (!this.socket) {
      return;
    }
    this.socket.close();
    this.socket = undefined;
    this.openPromise = undefined;
  }

  private handleMessage(data: WebSocket.RawData): void {
    const text = rawDataToString(data);
    let message: unknown;
    try {
      message = JSON.parse(text);
    } catch {
      this.emit("log", text);
      return;
    }

    if (!message || typeof message !== "object") {
      return;
    }

    const record = message as Partial<JsonRpcResponse & JsonRpcNotification>;
    if ("id" in record && record.id !== undefined) {
      const pending = this.pending.get(record.id);
      if (!pending) {
        this.emit("unhandledResponse", message);
        return;
      }
      clearTimeout(pending.timer);
      this.pending.delete(record.id);
      if (record.error) {
        pending.reject(new JsonRpcError(record.error.message ?? "JSON-RPC request failed", record.error.code, record.error.data));
      } else {
        pending.resolve(record.result);
      }
      return;
    }

    if (typeof record.method === "string") {
      this.emit("notification", record as JsonRpcNotification);
      this.emit(record.method, record.params);
    }
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

export function normalizeAppServerUrl(input: string): { url: string; socketPath?: string } {
  if (input.startsWith("unix://")) {
    const socketPath = input.slice("unix://".length);
    if (!socketPath) {
      throw new Error("unix app-server URL requires a socket path");
    }
    return { url: input, socketPath };
  }
  if (input.startsWith("ws://") || input.startsWith("wss://")) {
    return { url: input };
  }
  return { url: "ws://unix/", socketPath: input };
}

function rawDataToString(data: WebSocket.RawData): string {
  if (typeof data === "string") {
    return data;
  }
  if (Buffer.isBuffer(data)) {
    return data.toString("utf8");
  }
  if (Array.isArray(data)) {
    return Buffer.concat(data).toString("utf8");
  }
  return Buffer.from(data).toString("utf8");
}
