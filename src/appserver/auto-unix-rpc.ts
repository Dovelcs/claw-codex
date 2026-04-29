import { EventEmitter } from "node:events";
import type { JsonRpcNotification } from "./types.js";
import { UnixWebSocketJsonRpcClient } from "./unix-ws-rpc.js";
import { WebSocketJsonRpcClient } from "./ws-rpc.js";
import { ensureManagedAppServer } from "./managed-server.js";

interface RpcLike extends EventEmitter {
  request<T = unknown>(method: string, params?: unknown): Promise<T>;
  close(): void;
}

export interface AutoUnixWebSocketJsonRpcClientOptions {
  socketPath: string;
  requestTimeoutMs?: number;
  autoStart?: boolean;
}

export class AutoUnixWebSocketJsonRpcClient extends EventEmitter {
  private delegate?: RpcLike;

  constructor(private readonly options: AutoUnixWebSocketJsonRpcClientOptions) {
    super();
  }

  async request<T = unknown>(method: string, params?: unknown): Promise<T> {
    if (this.delegate) {
      return this.delegate.request<T>(method, params);
    }

    if (this.options.autoStart) {
      await ensureManagedAppServer({
        socketPath: this.options.socketPath,
        startupTimeoutMs: this.options.requestTimeoutMs
      });
    }

    const httpClient = new WebSocketJsonRpcClient({
      url: "ws://localhost/",
      socketPath: this.options.socketPath,
      requestTimeoutMs: this.options.requestTimeoutMs
    });

    try {
      const result = await httpClient.request<T>(method, params);
      this.setDelegate(httpClient);
      return result;
    } catch (httpError) {
      httpClient.close();
      const rawClient = new UnixWebSocketJsonRpcClient({
        socketPath: this.options.socketPath,
        requestTimeoutMs: this.options.requestTimeoutMs
      });
      try {
        const result = await rawClient.request<T>(method, params);
        this.setDelegate(rawClient);
        return result;
      } catch {
        rawClient.close();
        throw httpError;
      }
    }
  }

  close(): void {
    this.delegate?.close();
    this.delegate = undefined;
  }

  private setDelegate(delegate: RpcLike): void {
    this.delegate = delegate;
    delegate.on("notification", (notification: JsonRpcNotification) => this.emit("notification", notification));
    delegate.on("log", (line) => this.emit("log", line));
    delegate.on("close", (status) => this.emit("close", status));
    delegate.on("transportError", (error) => this.emit("transportError", error));
  }
}
