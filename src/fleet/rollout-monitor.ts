import fs from "node:fs/promises";

export interface RolloutTaskEvent {
  kind: "user_input" | "codex_reply" | "final_answer" | "task_started" | "task_complete";
  timestamp?: string | null;
  threadId: string;
  turnId?: string | null;
  role?: string | null;
  text?: string;
}

export interface WatchRolloutTaskOptions {
  rolloutPath: string;
  threadId: string;
  timeoutMs?: number;
  pollMs?: number;
  completeOnTaskComplete?: boolean;
  signal?: AbortSignal;
  onEvent: (event: RolloutTaskEvent) => void | Promise<void>;
}

export interface WatchRolloutTaskResult {
  completed: boolean;
  finalText?: string;
  turnId?: string;
}

export async function watchRolloutTask(options: WatchRolloutTaskOptions): Promise<WatchRolloutTaskResult> {
  let offset = await fileSize(options.rolloutPath);
  let buffer = "";
  const dedupe = new Set<string>();
  const startedAt = Date.now();
  const timeoutMs = options.timeoutMs ?? 30 * 60 * 1000;
  const pollMs = options.pollMs ?? 250;
  const result: WatchRolloutTaskResult = { completed: false };

  while (!options.signal?.aborted) {
    const size = await fileSize(options.rolloutPath);
    if (size < offset) {
      offset = 0;
      buffer = "";
    }
    if (size > offset) {
      const handle = await fs.open(options.rolloutPath, "r");
      try {
        const stream = handle.createReadStream({ start: offset, end: size - 1, encoding: "utf8" });
        let chunk = "";
        for await (const part of stream) {
          chunk += part;
        }
        offset = size;
        buffer += chunk;
      } finally {
        await handle.close();
      }

      const lines = buffer.split(/\n/);
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        for (const event of normalizeRolloutLine(line, options.threadId)) {
          const key = eventKey(event);
          if (dedupe.has(key)) {
            continue;
          }
          dedupe.add(key);
          if (event.kind === "final_answer" && event.text?.trim()) {
            result.finalText = event.text.trim();
          }
          if (event.kind === "codex_reply" && event.text?.trim() && !result.finalText) {
            result.finalText = event.text.trim();
          }
          if (event.kind === "task_started" && event.turnId) {
            result.turnId = event.turnId;
          }
          await options.onEvent(event);
          if (event.kind === "task_complete" && options.completeOnTaskComplete !== false) {
            result.completed = true;
            if (event.turnId) {
              result.turnId = event.turnId;
            }
            return result;
          }
        }
      }
    }

    if (timeoutMs > 0 && Date.now() - startedAt > timeoutMs) {
      return result;
    }
    await sleep(pollMs);
  }

  return result;
}

export function normalizeRolloutLine(line: string, threadId: string): RolloutTaskEvent[] {
  const text = line.trim();
  if (!text) {
    return [];
  }
  let record: unknown;
  try {
    record = JSON.parse(text);
  } catch {
    return [];
  }
  if (!isObject(record)) {
    return [];
  }
  const timestamp = stringValue(record.timestamp) ?? null;
  const payload = record.payload;
  if (!isObject(payload)) {
    return [];
  }

  if (record.type === "event_msg") {
    if (payload.type === "user_message") {
      return [{ kind: "user_input", timestamp, threadId, role: "user", text: stringValue(payload.message) ?? "" }];
    }
    if (payload.type === "agent_message") {
      return [{ kind: "codex_reply", timestamp, threadId, role: "assistant", text: stringValue(payload.message) ?? "" }];
    }
    if (payload.type === "task_started") {
      return [{ kind: "task_started", timestamp, threadId, turnId: stringValue(payload.turn_id) ?? null }];
    }
    if (payload.type === "task_complete") {
      return [{ kind: "task_complete", timestamp, threadId, turnId: stringValue(payload.turn_id) ?? null }];
    }
    return [];
  }

  if (record.type === "response_item" && payload.type === "message") {
    const role = stringValue(payload.role);
    if (role !== "user" && role !== "assistant") {
      return [];
    }
    return [{
      kind: role === "user" ? "user_input" : payload.phase === "final_answer" ? "final_answer" : "codex_reply",
      timestamp,
      threadId,
      role,
      text: contentText(payload.content)
    }];
  }

  return [];
}

function eventKey(event: RolloutTaskEvent): string {
  return JSON.stringify([
    event.kind,
    event.threadId,
    timestampBucket(event.timestamp),
    event.turnId,
    event.role,
    event.text
  ]);
}

function timestampBucket(value: unknown): unknown {
  return typeof value === "string" ? value.slice(0, 19) : value;
}

function contentText(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return "";
  }
  const parts: string[] = [];
  for (const item of content) {
    if (!isObject(item)) {
      continue;
    }
    for (const key of ["text", "input_text", "output_text"]) {
      const value = item[key];
      if (typeof value === "string") {
        parts.push(value);
        break;
      }
    }
  }
  return parts.join("\n").trim();
}

async function fileSize(file: string): Promise<number> {
  try {
    return (await fs.stat(file)).size;
  } catch {
    return 0;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
