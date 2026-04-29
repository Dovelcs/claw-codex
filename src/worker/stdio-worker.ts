import readline from "node:readline";
import { parseBridgeCommand } from "../bridge/commands.js";
import { WorkerCore } from "./core.js";
import type { WorkerIncomingMessage, WorkerOutgoingMessage } from "./protocol.js";

export class StdioWorker {
  private readonly core = new WorkerCore();

  async run(): Promise<void> {
    const rl = readline.createInterface({
      input: process.stdin,
      crlfDelay: Infinity
    });

    for await (const line of rl) {
      if (!line.trim()) {
        continue;
      }
      await this.handleLine(line);
    }
  }

  close(): void {
    this.core.close();
  }

  private async handleLine(line: string): Promise<void> {
    let incoming: WorkerIncomingMessage;
    try {
      incoming = parseIncomingMessage(line);
      const command = parseBridgeCommand(incoming.text);
      const outgoing = await this.core.execute(incoming.chatId, command);
      this.write(outgoing);
    } catch (error) {
      const fallbackChatId = tryReadChatId(line) ?? "unknown";
      this.write({
        type: "error",
        chatId: fallbackChatId,
        text: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private write(message: WorkerOutgoingMessage): void {
    process.stdout.write(`${JSON.stringify(message)}\n`);
  }
}

export function parseIncomingMessage(line: string): WorkerIncomingMessage {
  const value = JSON.parse(line) as Partial<WorkerIncomingMessage>;
  if (!value || typeof value !== "object") {
    throw new Error("worker input must be a JSON object");
  }
  if (typeof value.chatId !== "string" || !value.chatId.trim()) {
    throw new Error("worker input requires chatId");
  }
  if (typeof value.text !== "string" || !value.text.trim()) {
    throw new Error("worker input requires text");
  }
  return value.type === undefined
    ? { chatId: value.chatId, text: value.text }
    : { type: value.type, chatId: value.chatId, text: value.text };
}

function tryReadChatId(line: string): string | undefined {
  try {
    const value = JSON.parse(line) as Partial<WorkerIncomingMessage>;
    return typeof value.chatId === "string" ? value.chatId : undefined;
  } catch {
    return undefined;
  }
}
