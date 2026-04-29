import http from "node:http";
import { parseBridgeCommand } from "../bridge/commands.js";
import { WorkerCore } from "./core.js";
import type { WorkerIncomingMessage, WorkerOutgoingMessage } from "./protocol.js";
import { parseIncomingMessage } from "./stdio-worker.js";

export interface HttpWorkerOptions {
  host: string;
  port: number;
  token?: string;
}

export class HttpWorker {
  private readonly core = new WorkerCore();
  private server?: http.Server;

  constructor(private readonly options: HttpWorkerOptions) {}

  async listen(): Promise<void> {
    if (this.server) {
      return;
    }

    this.server = http.createServer((request, response) => {
      this.handle(request, response).catch((error) => {
        writeJson(response, 500, {
          type: "error",
          chatId: "unknown",
          text: error instanceof Error ? error.message : String(error)
        });
      });
    });

    await new Promise<void>((resolve, reject) => {
      this.server?.once("error", reject);
      this.server?.listen(this.options.port, this.options.host, () => {
        this.server?.off("error", reject);
        resolve();
      });
    });
  }

  close(): void {
    this.server?.close();
    this.server = undefined;
    this.core.close();
  }

  private async handle(request: http.IncomingMessage, response: http.ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

    if (request.method === "GET" && (url.pathname === "/healthz" || url.pathname === "/readyz")) {
      writeJson(response, 200, { ok: true });
      return;
    }

    if (request.method !== "POST" || (url.pathname !== "/message" && url.pathname !== "/v1/message")) {
      writeJson(response, 404, { ok: false, error: "not found" });
      return;
    }

    if (!this.authorized(request)) {
      writeJson(response, 401, { ok: false, error: "unauthorized" });
      return;
    }

    const raw = await readBody(request);
    let incoming: WorkerIncomingMessage;
    try {
      incoming = parseIncomingMessage(raw);
    } catch (error) {
      writeJson(response, 400, {
        type: "error",
        chatId: "unknown",
        text: error instanceof Error ? error.message : String(error)
      });
      return;
    }

    try {
      const command = parseBridgeCommand(incoming.text);
      const outgoing = await this.core.execute(incoming.chatId, command);
      writeJson(response, 200, outgoing);
    } catch (error) {
      const outgoing: WorkerOutgoingMessage = {
        type: "error",
        chatId: incoming.chatId,
        text: error instanceof Error ? error.message : String(error)
      };
      writeJson(response, 500, outgoing);
    }
  }

  private authorized(request: http.IncomingMessage): boolean {
    if (!this.options.token) {
      return true;
    }
    const authorization = request.headers.authorization;
    return authorization === `Bearer ${this.options.token}`;
  }
}

function readBody(request: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function writeJson(response: http.ServerResponse, statusCode: number, value: unknown): void {
  const body = Buffer.from(`${JSON.stringify(value)}\n`, "utf8");
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": String(body.length)
  });
  response.end(body);
}
