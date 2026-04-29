import fs from "node:fs";
import path from "node:path";
import type { ThreadSummary } from "../appserver/types.js";
import { defaultBridgeStatePath } from "../util/paths.js";

export interface ThreadBinding {
  threadId: string;
  updatedAt: string;
}

export interface CachedThread {
  id: string;
  shortId: string;
  title?: string | null;
  name?: string | null;
  source?: string | null;
  cwd?: string | null;
  updatedAt?: string | number | null;
}

export interface BridgeState {
  version: 1;
  activeProfile: string;
  bindings: Record<string, ThreadBinding>;
  recentThreads: CachedThread[];
}

export class StateStore {
  constructor(private readonly statePath = process.env.CODEX_BRIDGE_STATE ?? defaultBridgeStatePath()) {}

  load(): BridgeState {
    try {
      const raw = fs.readFileSync(this.statePath, "utf8");
      return normalizeState(JSON.parse(raw));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        throw error;
      }
      return createDefaultState();
    }
  }

  save(state: BridgeState): void {
    fs.mkdirSync(path.dirname(this.statePath), { recursive: true });
    fs.writeFileSync(this.statePath, `${JSON.stringify(state, null, 2)}\n`);
  }

  activeThread(profile = "default"): string | undefined {
    return this.load().bindings[profile]?.threadId;
  }

  setActiveThread(threadId: string, profile = "default"): void {
    const state = this.load();
    state.activeProfile = profile;
    state.bindings[profile] = {
      threadId,
      updatedAt: new Date().toISOString()
    };
    this.save(state);
  }

  updateRecentThreads(threads: ThreadSummary[]): CachedThread[] {
    const state = this.load();
    const cached = threads.map((thread) => ({
      id: thread.id,
      shortId: shortThreadId(thread.id),
      title: thread.title,
      name: thread.name,
      source: thread.source,
      cwd: thread.cwd,
      updatedAt: thread.updatedAt
    }));
    state.recentThreads = dedupeThreads([...cached, ...state.recentThreads]).slice(0, 100);
    this.save(state);
    return cached;
  }

  resolveThreadSelector(selector: string): CachedThread | undefined {
    const state = this.load();
    return resolveThreadSelector(selector, state.recentThreads);
  }
}

export function shortThreadId(threadId: string): string {
  return threadId.replace(/^thread-/, "").slice(0, 13);
}

export function resolveThreadSelector(selector: string, threads: CachedThread[]): CachedThread | undefined {
  const normalized = selector.trim();
  if (!normalized) {
    return undefined;
  }
  const fullId = threads.find((thread) => thread.id === normalized);
  if (fullId) {
    return fullId;
  }
  const shortMatches = threads.filter((thread) => thread.shortId === normalized);
  if (shortMatches.length === 1) {
    return shortMatches[0];
  }
  if (shortMatches.length > 1) {
    return undefined;
  }
  const prefixMatches = threads.filter((thread) => thread.id.startsWith(normalized) || thread.shortId.startsWith(normalized));
  return prefixMatches.length === 1 ? prefixMatches[0] : undefined;
}

function createDefaultState(): BridgeState {
  return {
    version: 1,
    activeProfile: "default",
    bindings: {},
    recentThreads: []
  };
}

function normalizeState(value: unknown): BridgeState {
  if (!value || typeof value !== "object") {
    return createDefaultState();
  }
  const record = value as Partial<BridgeState>;
  return {
    version: 1,
    activeProfile: record.activeProfile ?? "default",
    bindings: record.bindings ?? {},
    recentThreads: record.recentThreads ?? []
  };
}

function dedupeThreads(threads: CachedThread[]): CachedThread[] {
  const seen = new Set<string>();
  const result: CachedThread[] = [];
  for (const thread of threads) {
    if (seen.has(thread.id)) {
      continue;
    }
    seen.add(thread.id);
    result.push(thread);
  }
  return result;
}
