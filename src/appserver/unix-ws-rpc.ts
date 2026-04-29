import { randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import net from "node:net";
import { JsonRpcError } from "./json-rpc.js";
import type { JsonRpcNotification, JsonRpcRequest, JsonRpcResponse, RequestId } from "./types.js";

export interface UnixWebSocketJsonRpcClientOptions {
  socketPath: string;
  requestTimeoutMs?: number;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class UnixWebSocketJsonRpcClient extends EventEmitter {
  private socket?: net.Socket;
  private openPromise?: Promise<void>;
  private nextId = 1;
  private pending = new Map<RequestId, PendingRequest>();
  private receiveBuffer = Buffer.alloc(0);
  private readonly timeoutMs: number;

  constructor(private readonly options: UnixWebSocketJsonRpcClientOptions) {
    super();
    this.timeoutMs = options.requestTimeoutMs ?? 30_000;
  }

  async connect(): Promise<void> {
    if (this.socket && !this.socket.destroyed) {
      return;
    }
    if (this.openPromise) {
      return this.openPromise;
    }

    const socket = net.createConnection(this.options.socketPath);
    this.socket = socket;
    socket.on("data", (chunk) => this.handleData(chunk));
    socket.on("error", (error) => {
      this.emit("transportError", error);
      this.failAll(error);
    });
    socket.on("close", () => {
      this.emit("close", { code: 1006, reason: "unix socket closed" });
      this.failAll(new Error("app-server unix websocket closed"));
      this.socket = undefined;
      this.openPromise = undefined;
    });

    this.openPromise = new Promise((resolve, reject) => {
      const onConnect = () => {
        cleanup();
        resolve();
      };
      const onError = (error: Error) => {
        cleanup();
        reject(error);
      };
      const cleanup = () => {
        socket.off("connect", onConnect);
        socket.off("error", onError);
      };
      socket.once("connect", onConnect);
      socket.once("error", onError);
    });

    return this.openPromise;
  }

  async request<T = unknown>(method: string, params?: unknown): Promise<T> {
    await this.connect();
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

      try {
        this.sendText(JSON.stringify(payload));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  close(): void {
    this.socket?.end();
    this.socket = undefined;
    this.openPromise = undefined;
  }

  private sendText(text: string): void {
    const socket = this.socket;
    if (!socket || socket.destroyed) {
      throw new Error("app-server unix websocket is not open");
    }
    socket.write(encodeClientFrame(0x1, Buffer.from(text, "utf8")));
  }

  private handleData(chunk: Buffer): void {
    this.receiveBuffer = Buffer.concat([this.receiveBuffer, chunk]);
    for (;;) {
      const parsed = tryDecodeFrame(this.receiveBuffer);
      if (!parsed) {
        return;
      }
      this.receiveBuffer = this.receiveBuffer.subarray(parsed.consumed);
      this.handleFrame(parsed.opcode, parsed.payload);
    }
  }

  private handleFrame(opcode: number, payload: Buffer): void {
    if (opcode === 0x8) {
      this.socket?.end();
      return;
    }
    if (opcode === 0x9) {
      this.socket?.write(encodeClientFrame(0xA, payload));
      return;
    }
    if (opcode !== 0x1 && opcode !== 0x2) {
      return;
    }

    let message: unknown;
    const text = payload.toString("utf8");
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

export function unixSocketPathFromUrl(url: string): string | undefined {
  if (!url.startsWith("unix://")) {
    return undefined;
  }
  const socketPath = url.slice("unix://".length);
  if (!socketPath) {
    throw new Error("unix app-server URL requires a socket path");
  }
  return socketPath;
}

export function encodeClientFrame(opcode: number, payload: Buffer): Buffer {
  const mask = randomBytes(4);
  const length = payload.length;
  const headerLength = length < 126 ? 2 : length <= 0xffff ? 4 : 10;
  const frame = Buffer.alloc(headerLength + 4 + length);
  frame[0] = 0x80 | opcode;

  if (length < 126) {
    frame[1] = 0x80 | length;
  } else if (length <= 0xffff) {
    frame[1] = 0x80 | 126;
    frame.writeUInt16BE(length, 2);
  } else {
    frame[1] = 0x80 | 127;
    frame.writeBigUInt64BE(BigInt(length), 2);
  }

  mask.copy(frame, headerLength);
  for (let index = 0; index < length; index++) {
    frame[headerLength + 4 + index] = payload[index] ^ mask[index % 4];
  }
  return frame;
}

export function tryDecodeFrame(buffer: Buffer): { opcode: number; payload: Buffer; consumed: number } | undefined {
  if (buffer.length < 2) {
    return undefined;
  }

  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let length = buffer[1] & 0x7f;
  let offset = 2;

  if (length === 126) {
    if (buffer.length < offset + 2) {
      return undefined;
    }
    length = buffer.readUInt16BE(offset);
    offset += 2;
  } else if (length === 127) {
    if (buffer.length < offset + 8) {
      return undefined;
    }
    const bigLength = buffer.readBigUInt64BE(offset);
    if (bigLength > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error("websocket frame too large");
    }
    length = Number(bigLength);
    offset += 8;
  }

  let mask: Buffer | undefined;
  if (masked) {
    if (buffer.length < offset + 4) {
      return undefined;
    }
    mask = buffer.subarray(offset, offset + 4);
    offset += 4;
  }

  if (buffer.length < offset + length) {
    return undefined;
  }

  const payload = Buffer.from(buffer.subarray(offset, offset + length));
  if (mask) {
    for (let index = 0; index < payload.length; index++) {
      payload[index] = payload[index] ^ mask[index % 4];
    }
  }

  return {
    opcode,
    payload,
    consumed: offset + length
  };
}
