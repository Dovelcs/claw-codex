import { EventEmitter } from "node:events";
import {
  AppServerClient,
  type AppServerClientOptions
} from "../appserver/client.js";
import type { StartOrSteerResult, ThreadSummary } from "../appserver/types.js";
import { StateStore } from "./state.js";
import { extractActiveTurnId, extractStatus } from "./thread-utils.js";
import { VscodeIpcClient, type VscodeIpcClientOptions } from "../vscode-ipc/client.js";

export interface BridgeControllerOptions {
  appServer?: AppServerClientOptions;
  vscodeIpc?: VscodeIpcClientOptions | false;
  state?: StateStore;
  profile?: string;
}

export class BridgeController extends EventEmitter {
  readonly appServer: AppServerClient;
  readonly vscodeIpc?: VscodeIpcClient;
  readonly state: StateStore;
  readonly profile: string;

  constructor(options: BridgeControllerOptions = {}) {
    super();
    this.appServer = new AppServerClient(options.appServer);
    this.vscodeIpc = shouldUseVscodeIpc(options.vscodeIpc)
      ? new VscodeIpcClient(options.vscodeIpc === false ? undefined : options.vscodeIpc)
      : undefined;
    this.state = options.state ?? new StateStore();
    this.profile = options.profile ?? "default";
    this.appServer.on("notification", (notification) => this.emit("bridgeNotification", notification));
  }

  async connect(): Promise<void> {
    await this.appServer.connect();
  }

  async listVscodeThreads(limit = 20): Promise<ThreadSummary[]> {
    const threads = await this.appServer.threadList({ sourceKinds: ["vscode"], limit, useStateDbOnly: true });
    this.state.updateRecentThreads(threads);
    return threads;
  }

  async bindThread(selector: string): Promise<string> {
    let resolved = this.state.resolveThreadSelector(selector);
    if (!resolved && looksLikeFullThreadId(selector)) {
      const threadId = selector.trim();
      this.state.setActiveThread(threadId, this.profile);
      return threadId;
    }
    if (!resolved) {
      const threads = await this.listVscodeThreads(50);
      resolved = this.state.resolveThreadSelector(selector);
      if (!resolved && threads.some((thread) => thread.id === selector)) {
        resolved = { id: selector, shortId: selector.slice(0, 8) };
      }
    }
    if (!resolved) {
      throw new Error(`no cached VS Code Codex thread matches "${selector}"; run /vscode list first`);
    }
    this.state.setActiveThread(resolved.id, this.profile);
    await this.appServer.threadResume(resolved.id, { excludeTurns: true }).catch(() => undefined);
    return resolved.id;
  }

  async activeThreadId(): Promise<string> {
    const threadId = this.state.activeThread(this.profile);
    if (!threadId) {
      throw new Error("no VS Code Codex thread is bound; run /vscode list then /vscode use <short>");
    }
    return threadId;
  }

  async sendToActiveThread(text: string): Promise<StartOrSteerResult> {
    const threadId = await this.activeThreadId();
    if (!this.vscodeIpc) {
      throw new Error("VS Code IPC is disabled; refusing to use deprecated app-server write path");
    }
    return this.vscodeIpc.startTurn(threadId, text);
  }

  async stopActiveThread(): Promise<{ threadId: string; turnId?: string; transport?: string; response?: unknown }> {
    const threadId = await this.activeThreadId();
    if (!this.vscodeIpc) {
      throw new Error("VS Code IPC is disabled; refusing to use deprecated app-server interrupt path");
    }
    const response = await this.vscodeIpc.interruptTurn(threadId);
    return { threadId, transport: "vscode-ipc", response };
  }

  async status(): Promise<{ threadId: string; status?: string; activeTurnId?: string }> {
    const threadId = await this.activeThreadId();
    const thread = await this.appServer.threadRead(threadId, true).catch(() => undefined);
    return {
      threadId,
      status: extractStatus(thread),
      activeTurnId: extractActiveTurnId(thread)
    };
  }

  close(): void {
    this.appServer.close();
    this.vscodeIpc?.close();
  }

}

function shouldUseVscodeIpc(option: VscodeIpcClientOptions | false | undefined): boolean {
  return option !== false;
}

function looksLikeFullThreadId(selector: string): boolean {
  const value = selector.trim();
  return /^thread-[A-Za-z0-9_-]{8,}$/.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}
