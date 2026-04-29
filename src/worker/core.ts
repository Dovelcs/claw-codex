import { BridgeController } from "../bridge/controller.js";
import { type BridgeCommand } from "../bridge/commands.js";
import type { ThreadSummary } from "../appserver/types.js";
import { shortThreadId } from "../bridge/state.js";
import type { WorkerOutgoingMessage } from "./protocol.js";

export class WorkerCore {
  private readonly controllers = new Map<string, BridgeController>();

  async execute(chatId: string, command: BridgeCommand): Promise<WorkerOutgoingMessage> {
    const controller = this.controllerFor(chatId);

    switch (command.type) {
      case "vscode-list": {
        const threads = await controller.listVscodeThreads();
        const summaries = threads.map(publicThreadSummary);
        return {
          type: "threadList",
          chatId,
          text: formatThreadList(summaries),
          data: summaries
        };
      }

      case "vscode-use": {
        const threadId = await controller.bindThread(command.selector);
        return {
          type: "bound",
          chatId,
          text: `bound vscode thread ${threadId}`,
          data: { threadId }
        };
      }

      case "vscode-status": {
        const status = await controller.status();
        return {
          type: "status",
          chatId,
          text: status.activeTurnId ? `${status.status ?? "unknown"} turn=${status.activeTurnId}` : status.status ?? "unknown",
          data: status
        };
      }

      case "stop": {
        const stopped = await controller.stopActiveThread();
        const prefix = stopped.transport ? `interrupted ${stopped.transport}` : "interrupted";
        return {
          type: "stopped",
          chatId,
          text: stopped.turnId ? `${prefix} turn ${stopped.turnId}` : prefix,
          data: stopped
        };
      }

      case "send": {
        const result = await controller.sendToActiveThread(command.text);
        return {
          type: "sent",
          chatId,
          text: `message ${formatSendMode(result)}${result.turnId ? ` turn=${result.turnId}` : ""}`,
          data: result
        };
      }
    }
  }

  close(): void {
    for (const controller of this.controllers.values()) {
      controller.close();
    }
    this.controllers.clear();
  }

  private controllerFor(chatId: string): BridgeController {
    const existing = this.controllers.get(chatId);
    if (existing) {
      return existing;
    }
    const created = new BridgeController({ profile: chatId });
    this.controllers.set(chatId, created);
    return created;
  }
}

export interface PublicThreadSummary {
  id: string;
  shortId: string;
  title: string;
  source?: string | null;
  cwd?: string | null;
  updatedAt?: string | number | null;
}

export function publicThreadSummary(thread: ThreadSummary): PublicThreadSummary {
  return {
    id: thread.id,
    shortId: shortThreadId(thread.id),
    title: truncateCell(sanitizeCell(thread.title ?? thread.name ?? thread.preview ?? ""), 80),
    source: thread.source,
    cwd: thread.cwd,
    updatedAt: thread.updatedAt
  };
}

export function formatThreadList(threads: Array<ThreadSummary | PublicThreadSummary>): string {
  if (!threads.length) {
    return "no vscode Codex threads found";
  }
  return threads.map((thread) => {
    const title = "shortId" in thread
      ? thread.title
      : truncateCell(sanitizeCell(thread.title ?? thread.name ?? thread.preview ?? ""), 80);
    return `${"shortId" in thread ? thread.shortId : shortThreadId(thread.id)} ${title}`;
  }).join("\n");
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
