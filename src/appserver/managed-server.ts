import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

export interface ManagedAppServerOptions {
  socketPath: string;
  codexBin?: string;
  logPath?: string;
  startupTimeoutMs?: number;
}

const launchers = new Map<string, Promise<void>>();

export async function ensureManagedAppServer(options: ManagedAppServerOptions): Promise<void> {
  if (await socketAcceptsConnections(options.socketPath, 300)) {
    return;
  }

  const existing = launchers.get(options.socketPath);
  if (existing) {
    await existing;
    return;
  }

  const launch = startManagedAppServer(options).finally(() => {
    launchers.delete(options.socketPath);
  });
  launchers.set(options.socketPath, launch);
  await launch;
}

export function shouldAutoStartAppServer(value = process.env.CODEX_BRIDGE_AUTO_START_APPSERVER): boolean {
  if (value === undefined || value === "") {
    return false;
  }
  return /^(1|true|yes|on)$/i.test(value);
}

export function defaultManagedAppServerLogPath(): string {
  return path.join(os.homedir(), ".codex-bridge", "app-server.log");
}

export function findCodexBinary(): string {
  const explicit = process.env.CODEX_BRIDGE_CODEX_BIN ?? process.env.CODEX_BRIDGE_REAL_CODEX ?? process.env.CODEX_BIN;
  if (explicit) {
    return explicit;
  }

  const vscodeRoot = path.join(os.homedir(), ".vscode-server", "extensions");
  if (fs.existsSync(vscodeRoot)) {
    const extensionDirs = fs.readdirSync(vscodeRoot)
      .filter((name) => name.startsWith("openai.chatgpt-"))
      .sort()
      .reverse();
    for (const dir of extensionDirs) {
      const candidate = path.join(vscodeRoot, dir, "bin", "linux-x86_64", "codex");
      if (isExecutable(candidate)) {
        return candidate;
      }
    }
  }

  return "codex";
}

async function startManagedAppServer(options: ManagedAppServerOptions): Promise<void> {
  const socketPath = options.socketPath;
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });

  try {
    fs.unlinkSync(socketPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw error;
    }
  }

  const logPath = options.logPath ?? process.env.CODEX_BRIDGE_APP_SERVER_LOG ?? defaultManagedAppServerLogPath();
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logFd = fs.openSync(logPath, "a");
  const codexBin = options.codexBin ?? findCodexBinary();
  const child = spawn(codexBin, [
    "app-server",
    "--analytics-default-enabled",
    "--listen",
    `unix://${socketPath}`
  ], {
    detached: true,
    stdio: ["ignore", logFd, logFd],
    env: appServerEnv()
  });

  child.unref();
  child.once("error", () => {
    try {
      fs.closeSync(logFd);
    } catch {
      // Best effort only.
    }
  });
  child.once("exit", () => {
    try {
      fs.closeSync(logFd);
    } catch {
      // Best effort only.
    }
  });

  try {
    await waitForSocket(socketPath, options.startupTimeoutMs ?? 10_000);
  } catch (error) {
    throw new Error(`managed codex app-server did not become ready at ${socketPath}: ${errorMessage(error)}; log=${logPath}`);
  }
}

async function waitForSocket(socketPath: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await socketAcceptsConnections(socketPath, 300)) {
      return;
    }
    await sleep(100);
  }
  throw new Error(`timeout after ${timeoutMs}ms`);
}

function socketAcceptsConnections(socketPath: string, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    const done = (ok: boolean) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

function isExecutable(file: string): boolean {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function appServerEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env.CODEX_THREAD_ID;
  delete env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
  delete env.CODEX_BRIDGE_WRAPPED;
  return env;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
