import { setTimeout as delay } from "node:timers/promises";

export interface FleetManagerClientOptions {
  managerUrl: string;
  endpointId: string;
  token?: string;
  timeoutMs?: number;
}

export interface FleetCommand {
  command_id: string;
  endpoint_id: string;
  task_id?: string | null;
  type: "send" | "stop" | "refresh_sessions" | string;
  payload: Record<string, unknown>;
}

export interface FleetSession {
  id: string;
  source: string;
  title?: string | null;
  cwd?: string | null;
  status?: string | null;
  activeTurnId?: string | null;
  rolloutPath?: string | null;
}

export interface FleetChatBinding {
  channel: string;
  chat_id: string;
  profile?: string | null;
  endpoint_id?: string | null;
  project_alias?: string | null;
  session_id?: string | null;
  title?: string | null;
  session_policy?: string | null;
  updated_at?: string | null;
}

export interface FleetEvent {
  task_id?: string | null;
  session_id?: string | null;
  type: string;
  message?: string;
  data?: unknown;
}

export interface FleetCommandResult {
  command_id: string;
  task_id?: string | null;
  session_id?: string | null;
  ok: boolean;
  task_status?: string;
  summary?: string;
  error?: string;
}

export interface FleetTask {
  task_id: string;
  endpoint_id?: string | null;
  project_alias?: string | null;
  session_id?: string | null;
  prompt?: string | null;
  mode?: string | null;
  status?: string | null;
  last_summary?: string | null;
  profile?: string | null;
  chat_channel?: string | null;
  chat_id?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
}

export class FleetManagerClient {
  readonly managerUrl: string;
  private readonly timeoutMs: number;

  constructor(readonly options: FleetManagerClientOptions) {
    this.managerUrl = options.managerUrl.replace(/\/+$/, "");
    this.timeoutMs = options.timeoutMs ?? Number(process.env.CODEX_FLEET_HTTP_TIMEOUT_MS ?? 40000);
  }

  async register(label: string, capabilities: unknown, sessions: FleetSession[]): Promise<unknown> {
    return this.post("/api/worker/register", {
      endpoint_id: this.options.endpointId,
      label,
      capabilities,
      sessions
    });
  }

  async heartbeat(sessions: FleetSession[]): Promise<unknown> {
    return this.post("/api/worker/heartbeat", {
      endpoint_id: this.options.endpointId,
      sessions
    });
  }

  async poll(timeoutSeconds = 25): Promise<FleetCommand[]> {
    const payload = await this.get<{ commands?: FleetCommand[] }>(
      `/api/worker/poll?endpoint_id=${encodeURIComponent(this.options.endpointId)}&timeout=${timeoutSeconds}`
    );
    return Array.isArray(payload.commands) ? payload.commands : [];
  }

  async postEvents(payload: {
    sessions?: FleetSession[];
    events?: FleetEvent[];
    command_results?: FleetCommandResult[];
  }): Promise<unknown> {
    return this.post("/api/worker/events", {
      endpoint_id: this.options.endpointId,
      ...payload
    });
  }

  async chatBindings(channel?: string): Promise<FleetChatBinding[]> {
    const query = channel ? `?channel=${encodeURIComponent(channel)}` : "";
    const payload = await this.get<{ bindings?: FleetChatBinding[] }>(`/api/chat-bindings${query}`);
    return Array.isArray(payload.bindings) ? payload.bindings : [];
  }

  async tasks(): Promise<FleetTask[]> {
    const payload = await this.get<{ tasks?: FleetTask[] }>("/api/tasks");
    return Array.isArray(payload.tasks) ? payload.tasks : [];
  }

  async waitForManager(): Promise<void> {
    for (let attempt = 0; attempt < 30; attempt++) {
      try {
        await this.get("/healthz");
        return;
      } catch {
        await delay(1000);
      }
    }
    throw new Error(`fleet manager is not reachable: ${this.managerUrl}`);
  }

  private async get<T = unknown>(path: string): Promise<T> {
    return this.request<T>(path, { method: "GET" });
  }

  private async post<T = unknown>(path: string, body: unknown): Promise<T> {
    return this.request<T>(path, {
      method: "POST",
      body: JSON.stringify(body)
    });
  }

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    const controller = new AbortController();
    const timeout = Number.isFinite(this.timeoutMs) && this.timeoutMs > 0
      ? setTimeout(() => controller.abort(), this.timeoutMs)
      : undefined;
    const response = await fetch(`${this.managerUrl}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        ...(this.options.token ? { authorization: `Bearer ${this.options.token}` } : {}),
        ...(init.headers ?? {})
      }
    }).catch((error) => {
      if (error instanceof Error && error.name === "AbortError") {
        throw new Error(`fleet manager request timed out after ${this.timeoutMs}ms: ${path}`);
      }
      throw error;
    });
    try {
      const text = await response.text();
      const payload = text ? JSON.parse(text) : null;
      if (!response.ok) {
        throw new Error(`fleet manager HTTP ${response.status}: ${text}`);
      }
      return payload as T;
    } finally {
      if (timeout) {
        clearTimeout(timeout);
      }
    }
  }
}
