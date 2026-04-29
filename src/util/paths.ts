import os from "node:os";
import path from "node:path";

export function defaultAppServerSocketPath(): string {
  const runtimeDir = process.env.XDG_RUNTIME_DIR || path.join(os.tmpdir(), `codex-bridge-${process.getuid?.() ?? "user"}`);
  return path.join(runtimeDir, "app-server.sock");
}

export function defaultBridgeStatePath(): string {
  return path.join(os.homedir(), ".codex-bridge", "state.json");
}

export function repoRootFromDist(): string {
  return path.resolve(new URL("../../", import.meta.url).pathname);
}
