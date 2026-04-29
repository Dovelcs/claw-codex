#!/usr/bin/env node
import path from "node:path";
import process from "node:process";
import { BridgeController } from "./bridge/controller.js";
import { parseBridgeCommand } from "./bridge/commands.js";
import { shortThreadId } from "./bridge/state.js";
import { repoRootFromDist } from "./util/paths.js";
import { HttpWorker } from "./worker/http-worker.js";
import { WorkerAgent, type WorkerAgentOptions } from "./worker/agent.js";
import { StdioWorker } from "./worker/stdio-worker.js";

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || command === "help" || command === "--help" || command === "-h") {
    printHelp();
    return;
  }

  if (command === "wrapper-path") {
    console.log(path.join(repoRootFromDist(), "bin", "codex-vscode-wrapper.mjs"));
    return;
  }

  if (command === "parse") {
    const parsed = parseBridgeCommand(args.slice(1).join(" "));
    console.log(JSON.stringify(parsed, null, 2));
    return;
  }

  if (command === "worker") {
    const mode = args[1] ?? "stdio";
    if (mode === "agent") {
      const options = parseAgentArgs(args.slice(2));
      const agent = new WorkerAgent(options);
      process.once("SIGINT", () => agent.close());
      process.once("SIGTERM", () => agent.close());
      console.log(`codex bridge worker agent connecting to ${options.managerUrl} as ${options.endpointId}`);
      await agent.run();
      return;
    }
    if (mode === "serve") {
      const { host, port, token } = parseServeArgs(args.slice(2));
      const worker = new HttpWorker({ host, port, token });
      process.once("SIGINT", () => worker.close());
      process.once("SIGTERM", () => worker.close());
      await worker.listen();
      console.log(`codex bridge worker listening on http://${host}:${port}`);
      await new Promise(() => undefined);
      return;
    }
    if (mode !== "stdio") {
      throw new Error("usage: codex-vscode-bridge worker stdio|serve|agent");
    }
    const worker = new StdioWorker();
    process.once("SIGINT", () => worker.close());
    process.once("SIGTERM", () => worker.close());
    await worker.run();
    worker.close();
    return;
  }

  if (command !== "vscode") {
    throw new Error(`unknown command: ${command}`);
  }

  const controller = new BridgeController();
  try {
    const subcommand = args[1] ?? "list";
    if (subcommand === "list") {
      const threads = await controller.listVscodeThreads(Number(args[2]) || 20);
      printThreadTable(threads);
      return;
    }

    if (subcommand === "use") {
      const selector = args[2];
      if (!selector) {
        throw new Error("usage: codex-vscode-bridge vscode use <thread-id-or-short>");
      }
      const threadId = await controller.bindThread(selector);
      console.log(`bound vscode thread ${threadId}`);
      return;
    }

    if (subcommand === "send") {
      const text = args.slice(2).join(" ");
      if (!text) {
        throw new Error("usage: codex-vscode-bridge vscode send <message>");
      }
      const result = await controller.sendToActiveThread(text);
      console.log(`message ${formatSendMode(result)}${result.turnId ? ` turn=${result.turnId}` : ""}`);
      return;
    }

    if (subcommand === "stop") {
      const stopped = await controller.stopActiveThread();
      console.log(`interrupted ${stopped.transport ?? "turn"} thread=${stopped.threadId}${stopped.turnId ? ` turn=${stopped.turnId}` : ""}`);
      return;
    }

    if (subcommand === "status") {
      const status = await controller.status();
      console.log(JSON.stringify(status, null, 2));
      return;
    }

    throw new Error(`unknown vscode command: ${subcommand}`);
  } finally {
    controller.close();
  }
}

function printHelp(): void {
  console.log(`Usage:
  codex-vscode-bridge wrapper-path
  codex-vscode-bridge vscode list [limit]
  codex-vscode-bridge vscode use <thread-id-or-short>
  codex-vscode-bridge vscode send <message>
  codex-vscode-bridge vscode stop
  codex-vscode-bridge vscode status
  codex-vscode-bridge worker stdio
  codex-vscode-bridge worker serve --host <ip> --port <port>
  codex-vscode-bridge worker agent --manager <url> --endpoint <id> [--app-server-sock <path>|--app-server-url <url>]

Environment:
  CODEX_BRIDGE_APP_SERVER_SOCK  managed app-server unix socket
  CODEX_BRIDGE_APP_SERVER_URL   ws://... or unix://... app-server endpoint
  CODEX_BRIDGE_AUTO_START_APPSERVER  auto-start separate codex app-server for unix sockets, default 0
  CODEX_BRIDGE_CODEX_BIN        codex binary used for managed app-server
  CODEX_BRIDGE_APP_SERVER_LOG   managed app-server log file
  CODEX_BRIDGE_STATE            bridge state file
  CODEX_FLEET_URL               OpenWrt fleet manager URL
  CODEX_FLEET_ENDPOINT          worker endpoint id
  CODEX_FLEET_TOKEN             fleet manager bearer token
  CODEX_FLEET_REQUIRE_APPSERVER_FOR_VSCODE  legacy no-op; VS Code writes require official IPC`);
}

function parseServeArgs(args: string[]): { host: string; port: number; token?: string } {
  let host = process.env.CODEX_BRIDGE_WORKER_HOST ?? "127.0.0.1";
  let port = Number(process.env.CODEX_BRIDGE_WORKER_PORT ?? "17890");
  let token = process.env.CODEX_BRIDGE_TOKEN;

  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--host") {
      host = requiredValue(args[++index], "--host");
    } else if (arg === "--port") {
      port = Number(requiredValue(args[++index], "--port"));
    } else if (arg === "--token") {
      token = requiredValue(args[++index], "--token");
    } else {
      throw new Error(`unknown worker serve argument: ${arg}`);
    }
  }

  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`invalid port: ${port}`);
  }

  return { host, port, token };
}

function requiredValue(value: string | undefined, option: string): string {
  if (!value) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

function parseAgentArgs(args: string[]): WorkerAgentOptions {
  let managerUrl = process.env.CODEX_FLEET_URL ?? "";
  let endpointId = process.env.CODEX_FLEET_ENDPOINT ?? "company-main";
  let token = process.env.CODEX_FLEET_TOKEN;
  let label = process.env.CODEX_FLEET_LABEL;
  let sessionCacheMs = Number(process.env.CODEX_FLEET_SESSION_CACHE_MS ?? "60000");
  let appServerSocketPath = process.env.CODEX_BRIDGE_APP_SERVER_SOCK;
  let appServerUrl = appServerSocketPath ? undefined : process.env.CODEX_BRIDGE_APP_SERVER_URL;
  let requireAppServerForVscode = envBool(process.env.CODEX_FLEET_REQUIRE_APPSERVER_FOR_VSCODE, true);

  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--manager") {
      managerUrl = requiredValue(args[++index], "--manager");
    } else if (arg === "--endpoint") {
      endpointId = requiredValue(args[++index], "--endpoint");
    } else if (arg === "--token") {
      token = requiredValue(args[++index], "--token");
    } else if (arg === "--label") {
      label = requiredValue(args[++index], "--label");
    } else if (arg === "--session-cache-ms") {
      sessionCacheMs = Number(requiredValue(args[++index], "--session-cache-ms"));
    } else if (arg === "--app-server-url") {
      appServerUrl = requiredValue(args[++index], "--app-server-url");
    } else if (arg === "--app-server-sock") {
      appServerSocketPath = requiredValue(args[++index], "--app-server-sock");
      appServerUrl = undefined;
    } else if (arg === "--require-app-server") {
      requireAppServerForVscode = true;
    } else if (arg === "--allow-resume-fallback") {
      throw new Error("--allow-resume-fallback was removed; VS Code sessions must use official IPC");
    } else {
      throw new Error(`unknown worker agent argument: ${arg}`);
    }
  }

  if (!managerUrl) {
    throw new Error("worker agent requires --manager or CODEX_FLEET_URL");
  }
  if (!endpointId) {
    throw new Error("worker agent requires --endpoint or CODEX_FLEET_ENDPOINT");
  }

  if (!Number.isFinite(sessionCacheMs) || sessionCacheMs < 0) {
    throw new Error(`invalid --session-cache-ms: ${sessionCacheMs}`);
  }

  return {
    managerUrl,
    endpointId,
    token,
    label,
    sessionCacheMs,
    appServerUrl,
    appServerSocketPath,
    requireAppServerForVscode
  };
}

function envBool(value: string | undefined, defaultValue: boolean): boolean {
  if (value === undefined || value === "") {
    return defaultValue;
  }
  if (/^(1|true|yes|on)$/i.test(value)) {
    return true;
  }
  if (/^(0|false|no|off)$/i.test(value)) {
    return false;
  }
  return defaultValue;
}

function printThreadTable(threads: Array<{ id: string; title?: string | null; name?: string | null; preview?: string | null; source?: string | null; cwd?: string | null; updatedAt?: string | number | null }>): void {
  if (!threads.length) {
    console.log("no vscode Codex threads found");
    return;
  }
  console.log(["short", "source", "updated", "title", "cwd"].join("\t"));
  for (const thread of threads) {
    console.log([
      shortThreadId(thread.id),
      thread.source ?? "",
      String(thread.updatedAt ?? ""),
      truncateCell(sanitizeCell(thread.title ?? thread.name ?? thread.preview ?? ""), 80),
      sanitizeCell(thread.cwd ?? "")
    ].join("\t"));
  }
}

function sanitizeCell(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function truncateCell(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 3).trimEnd()}...`;
}

function formatSendMode(result: { mode: string; transport?: string }): string {
  return result.transport ? `${result.transport} ${result.mode}` : result.mode;
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
