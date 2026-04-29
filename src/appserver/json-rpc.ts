import { EventEmitter } from "node:events";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { JsonRpcNotification, JsonRpcRequest, JsonRpcResponse, RequestId } from "./types.js";

export interface JsonRpcProcessClientOptions {
  command: string;
  args: string[];
  env?: NodeJS.ProcessEnv;
  cwd?: string;
}

export interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

export class JsonRpcError extends Error {
  readonly code?: number;
  readonly data?: unknown;

  constructor(message: string, code?: number, data?: unknown) {
    super(message);
    this.name = "JsonRpcError";
    this.code = code;
    this.data = data;
  }
}

export function splitJsonLines(buffer: string, chunk: string): { lines: string[]; rest: string } {
  const joined = buffer + chunk;
  const parts = joined.split(/\r?\n/);
  const rest = parts.pop() ?? "";
  return { lines: parts, rest };
}

export function parseJsonLine(line: string): unknown | undefined {
  const trimmed = line.trim();
  if (!trimmed) {
    return undefined;
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}

export class JsonRpcProcessClient extends EventEmitter {
  private child?: ChildProcessWithoutNullStreams;
  private nextId = 1;
  private pending = new Map<RequestId, PendingRequest>();
  private stdoutBuffer = "";
  private stderrBuffer = "";

  constructor(private readonly options: JsonRpcProcessClientOptions) {
    super();
  }

  start(): void {
    if (this.child) {
      return;
    }

    this.child = spawn(this.options.command, this.options.args, {
      cwd: this.options.cwd,
      env: this.options.env ?? process.env,
      stdio: ["pipe", "pipe", "pipe"]
    });

    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");

    this.child.stdout.on("data", (chunk: string) => this.handleStdout(chunk));
    this.child.stderr.on("data", (chunk: string) => this.handleStderr(chunk));
    this.child.on("error", (error) => this.failAll(error));
    this.child.on("exit", (code, signal) => {
      const reason = signal ? `signal ${signal}` : `code ${code ?? 0}`;
      this.failAll(new Error(`app-server proxy exited with ${reason}`));
      this.emit("exit", { code, signal });
    });
  }

  async request<T = unknown>(method: string, params?: unknown): Promise<T> {
    this.start();
    const id = this.nextId++;
    const payload: JsonRpcRequest = params === undefined ? { id, method } : { id, method, params };

    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject
      });
      this.child?.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
        if (error) {
          this.pending.delete(id);
          reject(error);
        }
      });
    });
  }

  close(): void {
    if (!this.child) {
      return;
    }
    this.child.kill("SIGTERM");
    this.child = undefined;
  }

  private handleStdout(chunk: string): void {
    const split = splitJsonLines(this.stdoutBuffer, chunk);
    this.stdoutBuffer = split.rest;
    for (const line of split.lines) {
      const message = parseJsonLine(line);
      if (message !== undefined) {
        this.handleMessage(message);
      } else if (line.trim()) {
        this.emit("log", line);
      }
    }
  }

  private handleStderr(chunk: string): void {
    const split = splitJsonLines(this.stderrBuffer, chunk);
    this.stderrBuffer = split.rest;
    for (const line of split.lines) {
      if (line.trim()) {
        this.emit("stderr", line);
      }
    }
  }

  private handleMessage(message: unknown): void {
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
      pending.reject(error);
    }
    this.pending.clear();
  }
}
