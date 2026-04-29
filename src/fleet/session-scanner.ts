import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { FleetSession } from "./manager-client.js";

const execFileAsync = promisify(execFile);

export interface CodexSessionScannerOptions {
  codexHome?: string;
  limit?: number;
  sqliteBin?: string;
}

interface ScannedSession extends FleetSession {
  updatedAt?: string | number | null;
  createdAt?: string | number | null;
  model?: string | null;
  scanSource?: "sqlite" | "jsonl";
  rolloutPath?: string | null;
}

interface ThreadDbRow {
  id?: string;
  title?: string;
  cwd?: string;
  source?: string;
  model?: string;
  rollout_path?: string;
  updated_at_ms?: number;
  created_at_ms?: number;
  updated_at?: number;
  created_at?: number;
}

export class CodexSessionScanner {
  private readonly codexHome: string;
  private readonly limit: number;
  private readonly sqliteBin: string;

  constructor(options: CodexSessionScannerOptions = {}) {
    this.codexHome = options.codexHome ?? process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex");
    this.limit = options.limit ?? 50;
    this.sqliteBin = options.sqliteBin ?? process.env.CODEX_FLEET_SQLITE ?? "sqlite3";
  }

  async scan(): Promise<FleetSession[]> {
    const sessions = new Map<string, ScannedSession>();
    for (const session of await this.scanSqlite()) {
      sessions.set(session.id, session);
    }
    for (const session of await this.scanJsonl()) {
      if (!sessions.has(session.id)) {
        sessions.set(session.id, session);
      }
    }
    return [...sessions.values()]
      .sort((left, right) => timestamp(right.updatedAt) - timestamp(left.updatedAt))
      .slice(0, this.limit);
  }

  private async scanSqlite(): Promise<ScannedSession[]> {
    const dbs = await this.stateDbPaths();
    const sessions: ScannedSession[] = [];
    for (const db of dbs) {
      try {
        const { stdout } = await execFileAsync(this.sqliteBin, [
          "-readonly",
          "-json",
          db,
          `select id,title,cwd,source,model,rollout_path,updated_at_ms,created_at_ms,updated_at,created_at
             from threads
            where archived = 0
            order by coalesce(updated_at_ms, updated_at * 1000) desc, id desc
            limit ${Math.max(this.limit, 100)}`
        ], { maxBuffer: 1024 * 1024 * 8 });
        const rows = JSON.parse(stdout || "[]") as ThreadDbRow[];
        for (const row of rows) {
          const session = sessionFromDbRow(row);
          if (session) {
            sessions.push(session);
          }
        }
      } catch {
        continue;
      }
    }
    return dedupe(sessions);
  }

  private async stateDbPaths(): Promise<string[]> {
    const paths: string[] = [];
    const rootDb = path.join(this.codexHome, "state_5.sqlite");
    if (await exists(rootDb)) {
      paths.push(rootDb);
    }
    const accountsDir = path.join(this.codexHome, "accounts");
    try {
      for (const entry of await fs.readdir(accountsDir, { withFileTypes: true })) {
        if (!entry.isDirectory()) {
          continue;
        }
        const accountDb = path.join(accountsDir, entry.name, "state_5.sqlite");
        if (await exists(accountDb)) {
          paths.push(accountDb);
        }
      }
    } catch {
      // No accounts directory is a normal single-account setup.
    }
    return paths;
  }

  private async scanJsonl(): Promise<ScannedSession[]> {
    const sessionsDir = path.join(this.codexHome, "sessions");
    const files = await collectJsonlFiles(sessionsDir);
    const sessions: ScannedSession[] = [];
    for (const file of files.slice(0, Math.max(this.limit * 3, 100))) {
      const session = await sessionFromJsonl(file);
      if (session) {
        sessions.push(session);
      }
    }
    return dedupe(sessions);
  }
}

export function mergeFleetSessions(primary: FleetSession[], fallback: FleetSession[], limit = 50): FleetSession[] {
  const merged = new Map<string, FleetSession>();
  for (const session of primary) {
    merged.set(session.id, session);
  }
  for (const session of fallback) {
    const existing = merged.get(session.id);
    if (!existing) {
      merged.set(session.id, session);
    } else if (!existing.rolloutPath && session.rolloutPath) {
      merged.set(session.id, { ...session, ...existing, rolloutPath: session.rolloutPath });
    }
  }
  return [...merged.values()].slice(0, limit);
}

function sessionFromDbRow(row: ThreadDbRow): ScannedSession | undefined {
  if (!row.id) {
    return undefined;
  }
  const updatedAt = row.updated_at_ms ?? (typeof row.updated_at === "number" ? row.updated_at * 1000 : undefined);
  const createdAt = row.created_at_ms ?? (typeof row.created_at === "number" ? row.created_at * 1000 : undefined);
  return {
    id: row.id,
    source: row.source || "unknown",
    title: row.title || null,
    cwd: row.cwd || null,
    updatedAt,
    createdAt,
    model: row.model || null,
    scanSource: "sqlite",
    rolloutPath: row.rollout_path || null
  };
}

async function sessionFromJsonl(file: string): Promise<ScannedSession | undefined> {
  try {
    const content = await fs.readFile(file, "utf8");
    let meta: Record<string, unknown> | undefined;
    let firstUserText = "";
    for (const line of content.split("\n")) {
      if (!line.trim()) {
        continue;
      }
      const record = JSON.parse(line) as Record<string, unknown>;
      if (record.type === "session_meta" && isObject(record.payload)) {
        meta = record.payload;
      }
      if (!firstUserText) {
        firstUserText = userTextFromRecord(record);
      }
      if (meta && firstUserText) {
        break;
      }
    }
    if (!meta || typeof meta.id !== "string") {
      return undefined;
    }
    const stat = await fs.stat(file);
    return {
      id: meta.id,
      source: stringValue(meta.source) ?? sourceFromOriginator(stringValue(meta.originator)),
      title: firstUserText || stringValue(meta.title) || null,
      cwd: stringValue(meta.cwd) ?? null,
      updatedAt: stat.mtimeMs,
      createdAt: stringValue(meta.timestamp) ?? stat.birthtimeMs,
      model: stringValue(meta.model) ?? null,
      scanSource: "jsonl",
      rolloutPath: file
    };
  } catch {
    return undefined;
  }
}

function userTextFromRecord(record: Record<string, unknown>): string {
  if (record.type !== "response_item" || !isObject(record.payload)) {
    return "";
  }
  const payload = record.payload;
  if (payload.type !== "message" || payload.role !== "user" || !Array.isArray(payload.content)) {
    return "";
  }
  const parts: string[] = [];
  for (const item of payload.content) {
    if (isObject(item) && item.type === "input_text" && typeof item.text === "string") {
      parts.push(item.text);
    }
  }
  return truncate(parts.join(" ").replace(/\s+/g, " ").trim(), 80);
}

async function collectJsonlFiles(root: string): Promise<string[]> {
  const result: Array<{ file: string; mtimeMs: number }> = [];
  async function walk(dir: string): Promise<void> {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        const stat = await fs.stat(full);
        result.push({ file: full, mtimeMs: stat.mtimeMs });
      }
    }
  }
  await walk(root);
  return result.sort((left, right) => right.mtimeMs - left.mtimeMs).map((entry) => entry.file);
}

function dedupe(sessions: ScannedSession[]): ScannedSession[] {
  const seen = new Map<string, ScannedSession>();
  for (const session of sessions) {
    const existing = seen.get(session.id);
    if (!existing || timestamp(session.updatedAt) > timestamp(existing.updatedAt)) {
      seen.set(session.id, session);
    }
  }
  return [...seen.values()].sort((left, right) => timestamp(right.updatedAt) - timestamp(left.updatedAt));
}

function timestamp(value: unknown): number {
  if (typeof value === "number") {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

async function exists(file: string): Promise<boolean> {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

function sourceFromOriginator(originator?: string): string {
  return originator === "codex_vscode" ? "vscode" : "unknown";
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function truncate(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 3).trimEnd()}...`;
}
