import { EventEmitter } from "node:events";
import type {
  TextUserInput,
  ThreadListResponse,
  ThreadReadResponse,
  ThreadSummary
} from "./types.js";
import { defaultAppServerSocketPath } from "../util/paths.js";
import { WebSocketJsonRpcClient } from "./ws-rpc.js";
import { UnixWebSocketJsonRpcClient, unixSocketPathFromUrl } from "./unix-ws-rpc.js";
import { AutoUnixWebSocketJsonRpcClient } from "./auto-unix-rpc.js";
import { shouldAutoStartAppServer } from "./managed-server.js";

export interface AppServerClientOptions {
  appServerUrl?: string;
  socketPath?: string;
  clientName?: string;
  clientVersion?: string;
  requestTimeoutMs?: number;
  autoStart?: boolean;
}

export class AppServerClient extends EventEmitter {
  private readonly rpc: WebSocketJsonRpcClient | UnixWebSocketJsonRpcClient | AutoUnixWebSocketJsonRpcClient;
  private initialized = false;

  constructor(private readonly options: AppServerClientOptions = {}) {
    super();
    const socketPath = options.socketPath ?? process.env.CODEX_BRIDGE_APP_SERVER_SOCK ?? defaultAppServerSocketPath();
    const appServerUrl = options.appServerUrl ?? process.env.CODEX_BRIDGE_APP_SERVER_URL ?? `unix://${socketPath}`;
    const unixSocketPath = unixSocketPathFromUrl(appServerUrl);
    this.rpc = unixSocketPath
      ? new AutoUnixWebSocketJsonRpcClient({
          socketPath: unixSocketPath,
          requestTimeoutMs: options.requestTimeoutMs,
          autoStart: options.autoStart ?? shouldAutoStartAppServer()
        })
      : new WebSocketJsonRpcClient({ url: appServerUrl, requestTimeoutMs: options.requestTimeoutMs });
    this.rpc.on("notification", (notification) => this.emit("notification", notification));
    this.rpc.on("log", (line) => this.emit("log", line));
    this.rpc.on("close", (status) => this.emit("close", status));
    this.rpc.on("transportError", (error) => this.emit("transportError", error));
  }

  async connect(): Promise<void> {
    if (this.initialized) {
      return;
    }
    await this.rpc.request("initialize", {
      clientInfo: {
        name: this.options.clientName ?? "codex-vscode-bridge",
        title: "Codex VS Code Bridge",
        version: this.options.clientVersion ?? "0.1.0"
      },
      capabilities: {
        experimentalApi: true
      }
    });
    this.initialized = true;
  }

  async threadList(params: {
    sourceKinds?: string[];
    limit?: number;
    searchTerm?: string;
    cwd?: string | string[];
    useStateDbOnly?: boolean;
  } = {}): Promise<ThreadSummary[]> {
    await this.connect();
    const response = await this.rpc.request<ThreadListResponse>("thread/list", {
      sourceKinds: params.sourceKinds ?? ["vscode"],
      limit: params.limit ?? 20,
      sortKey: "updated_at",
      sortDirection: "desc",
      searchTerm: params.searchTerm,
      cwd: params.cwd,
      useStateDbOnly: params.useStateDbOnly ?? true
    });
    return normalizeThreadList(response);
  }

  async threadRead(threadId: string, includeTurns = true): Promise<unknown> {
    await this.connect();
    const response = await this.rpc.request<ThreadReadResponse>("thread/read", { threadId, includeTurns });
    return response.thread ?? response;
  }

  async threadResume(threadId: string, options: { excludeTurns?: boolean } = {}): Promise<unknown> {
    await this.connect();
    return this.rpc.request("thread/resume", { threadId, excludeTurns: options.excludeTurns });
  }

  close(): void {
    this.rpc.close();
  }
}

export function textInput(text: string): TextUserInput {
  return { type: "text", text, text_elements: [] };
}

export function normalizeThreadList(response: ThreadListResponse | ThreadSummary[] | unknown): ThreadSummary[] {
  if (Array.isArray(response)) {
    return response as ThreadSummary[];
  }
  if (response && typeof response === "object") {
    const record = response as ThreadListResponse;
    if (Array.isArray(record.data)) {
      return record.data;
    }
    if (Array.isArray(record.threads)) {
      return record.threads;
    }
  }
  return [];
}

export function extractTurnId(value: unknown): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  for (const key of ["turnId", "turn_id", "id"]) {
    const candidate = record[key];
    if (typeof candidate === "string") {
      return candidate;
    }
  }
  const turn = record.turn;
  if (turn && typeof turn === "object") {
    return extractTurnId(turn);
  }
  return undefined;
}
