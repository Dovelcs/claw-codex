import { spawn, type ChildProcess } from "node:child_process";
import readline from "node:readline";
import { BridgeController } from "../bridge/controller.js";
import type { AppServerClientOptions } from "../appserver/client.js";
import type { ThreadSummary } from "../appserver/types.js";
import { FleetManagerClient, type FleetCommand, type FleetCommandResult, type FleetEvent, type FleetSession } from "../fleet/manager-client.js";
import { watchRolloutTask, type RolloutTaskEvent } from "../fleet/rollout-monitor.js";
import { CodexSessionScanner, mergeFleetSessions } from "../fleet/session-scanner.js";

export interface WorkerAgentOptions {
  managerUrl: string;
  endpointId: string;
  token?: string;
  label?: string;
  heartbeatIntervalMs?: number;
  pollTimeoutSeconds?: number;
  sessionCacheMs?: number;
  appServerUrl?: string;
  appServerSocketPath?: string;
  requireAppServerForVscode?: boolean;
}

interface HeadlessRun {
  taskId?: string | null;
  sessionId: string;
  process: ChildProcess;
  mode: "headless";
  finalText?: string;
  timedOut?: boolean;
}

export class WorkerAgent {
  private readonly manager: FleetManagerClient;
  private readonly sessionScanner = new CodexSessionScanner();
  private readonly controllers = new Map<string, BridgeController>();
  private readonly headlessRuns = new Map<string, HeadlessRun>();
  private readonly rolloutWatches = new Set<AbortController>();
  private readonly sessionMirrorWatches = new Map<string, AbortController>();
  private readonly taskBySession = new Map<string, string>();
  private readonly recentTaskMirrorSuppressions = new Map<string, number>();
  private sessionCache: FleetSession[] = [];
  private sessionCacheExpiresAt = 0;
  private sessionDiscovery?: Promise<FleetSession[]>;
  private closed = false;

  constructor(private readonly options: WorkerAgentOptions) {
    this.manager = new FleetManagerClient({
      managerUrl: options.managerUrl,
      endpointId: options.endpointId,
      token: options.token
    });
  }

  async run(): Promise<void> {
    await this.manager.waitForManager();
    await this.register();
    const heartbeat = setInterval(() => {
      this.sendHeartbeat().catch((error) => this.reportAgentError(error));
    }, this.options.heartbeatIntervalMs ?? 15000);

    try {
      while (!this.closed) {
        const commands = await this.manager.poll(this.options.pollTimeoutSeconds ?? 25);
        for (const command of commands) {
          await this.executeAndReport(command);
        }
      }
    } finally {
      clearInterval(heartbeat);
      this.close();
    }
  }

  close(): void {
    this.closed = true;
    for (const controller of this.controllers.values()) {
      controller.close();
    }
    this.controllers.clear();
    for (const run of this.headlessRuns.values()) {
      run.process.kill("SIGTERM");
    }
    this.headlessRuns.clear();
    for (const watch of this.rolloutWatches) {
      watch.abort();
    }
    this.rolloutWatches.clear();
    for (const watch of this.sessionMirrorWatches.values()) {
      watch.abort();
    }
    this.sessionMirrorWatches.clear();
    this.recentTaskMirrorSuppressions.clear();
  }

  async register(): Promise<void> {
    const sessions = await this.discoverSessions({ force: true });
    await this.manager.register(this.options.label ?? this.options.endpointId, {
      vscode: true,
      headless: true,
      worker: "codex-vscode-bridge"
    }, sessions);
    await this.ensureSessionMirrors(sessions);
  }

  async sendHeartbeat(): Promise<void> {
    const sessions = await this.discoverSessions();
    await this.manager.heartbeat(sessions);
    await this.ensureSessionMirrors(sessions);
  }

  async executeCommand(command: FleetCommand): Promise<{ result: FleetCommandResult; events: FleetEvent[]; sessions?: FleetSession[] }> {
    if (command.type === "refresh_sessions") {
      return {
        result: this.ok(command, undefined, "idle", "sessions refreshed"),
        events: [event(command, "sessions/refreshed", "sessions refreshed")],
        sessions: await this.discoverSessions({ force: true })
      };
    }
    if (command.type === "stop") {
      return this.stop(command);
    }
    if (command.type === "send") {
      return this.send(command);
    }
    return {
      result: this.fail(command, `unsupported command type: ${command.type}`),
      events: [event(command, "task/error", `unsupported command type: ${command.type}`)]
    };
  }

  private async executeAndReport(command: FleetCommand): Promise<void> {
    try {
      const response = await this.executeCommand(command);
      await this.manager.postEvents({
        sessions: response.sessions,
        command_results: [response.result],
        events: response.events
      });
    } catch (error) {
      await this.manager.postEvents({
        command_results: [this.fail(command, errorMessage(error))],
        events: [event(command, "task/error", errorMessage(error))]
      });
    }
  }

  private async send(command: FleetCommand): Promise<{ result: FleetCommandResult; events: FleetEvent[]; sessions?: FleetSession[] }> {
    const prompt = stringValue(command.payload.prompt);
    if (!prompt) {
      return { result: this.fail(command, "send command requires prompt"), events: [event(command, "task/error", "send command requires prompt")] };
    }

    if (stringValue(command.payload.mode) === "headless") {
      const sessionId = this.startHeadless(command, prompt);
      return {
        result: this.ok(command, sessionId, "running", `headless task started ${sessionId}`),
        events: [event(command, "task/started", `headless task started ${sessionId}`, { session_id: sessionId })]
      };
    }

    const sessionId = await this.resolveVscodeSession(command);
    const session = await this.sessionById(sessionId);
    if (!shouldUseVscodeIpcForSession(session)) {
      return {
        result: this.fail(command, `session ${sessionId} is not a VS Code session; refusing deprecated resume fallback`),
        events: [event(command, "task/error", `session ${sessionId} is not a VS Code session; refusing deprecated resume fallback`, { session_id: sessionId, session_source: session?.source ?? "unknown" })],
        sessions: await this.discoverSessions()
      };
    }
    const controller = this.controllerFor(sessionId);
    await controller.bindThread(sessionId);
    this.rememberTask(command, sessionId);
    const rolloutWatch = this.watchVscodeRollout(command, session);
    let sent;
    try {
      sent = await controller.sendToActiveThread(prompt);
    } catch (error) {
      rolloutWatch?.abort();
      throw error;
    }
    const sentMode = formatSendMode(sent);
    return {
      result: this.ok(command, sessionId, "running", `message ${sentMode}${sent.turnId ? ` turn=${sent.turnId}` : ""}`),
      events: [event(command, "turn/sent", `message ${sentMode}`, { session_id: sessionId, turn_id: sent.turnId, mode: sent.mode, transport: sent.transport, rollout_path: session?.rolloutPath })],
      sessions: await this.discoverSessions()
    };
  }

  private async stop(command: FleetCommand): Promise<{ result: FleetCommandResult; events: FleetEvent[]; sessions?: FleetSession[] }> {
    const taskId = command.task_id ?? stringValue(command.payload.task_id);
    if (taskId && this.headlessRuns.has(taskId)) {
      this.headlessRuns.get(taskId)?.process.kill("SIGTERM");
      return {
        result: this.ok(command, this.headlessRuns.get(taskId)?.sessionId, "cancelled", "headless task interrupted"),
        events: [event(command, "turn/aborted", "headless task interrupted")]
      };
    }

    const sessionId = stringValue(command.payload.session_id) || await this.resolveVscodeSession(command);
    const controller = this.controllerFor(sessionId);
    await controller.bindThread(sessionId);
    const stopped = await controller.stopActiveThread();
    this.taskBySession.delete(sessionId);
    const stopPrefix = stopped.transport ? `interrupted ${stopped.transport}` : "interrupted";
    return {
      result: this.ok(command, sessionId, "cancelled", stopped.turnId ? `${stopPrefix} ${stopped.turnId}` : stopPrefix),
      events: [event(command, "turn/aborted", stopped.turnId ? `${stopPrefix} ${stopped.turnId}` : stopPrefix, { session_id: sessionId, turn_id: stopped.turnId, transport: stopped.transport })],
      sessions: await this.discoverSessions()
    };
  }

  private async resolveVscodeSession(command: FleetCommand): Promise<string> {
    const direct = stringValue(command.payload.session_id);
    if (direct) {
      return direct;
    }
    const project = objectValue(command.payload.project);
    const projectPath = stringValue(project?.path);
    const sessions = await this.discoverSessions();
    const byProject = projectPath ? sessions.find((session) => session.cwd === projectPath) : undefined;
    if (byProject) {
      return byProject.id;
    }
    const latest = sessions.find((session) => session.source === "vscode");
    if (latest) {
      return latest.id;
    }
    throw new Error("no VS Code session is available for this command");
  }

  private async sessionById(sessionId: string): Promise<FleetSession | undefined> {
    return (await this.discoverSessions()).find((session) => session.id === sessionId);
  }

  private async discoverSessions(options: { force?: boolean } = {}): Promise<FleetSession[]> {
    const now = Date.now();
    if (!options.force && this.sessionCache.length && now < this.sessionCacheExpiresAt) {
      return this.sessionCache;
    }
    if (this.sessionDiscovery) {
      return this.sessionDiscovery;
    }
    this.sessionDiscovery = this.refreshSessions()
      .finally(() => {
        this.sessionDiscovery = undefined;
      });
    return this.sessionDiscovery;
  }

  private async refreshSessions(): Promise<FleetSession[]> {
    const fallback = await this.sessionScanner.scan();
    const controller = new BridgeController({ profile: "fleet-discovery", appServer: workerAppServerOptions(this.options) });
    try {
      const threads = await controller.listVscodeThreads(50);
      return this.rememberSessions(mergeFleetSessions(threads.map(threadToFleetSession), fallback));
    } catch {
      return this.rememberSessions(fallback);
    } finally {
      controller.close();
    }
  }

  private rememberSessions(sessions: FleetSession[]): FleetSession[] {
    this.sessionCache = sessions;
    this.sessionCacheExpiresAt = Date.now() + (this.options.sessionCacheMs ?? Number(process.env.CODEX_FLEET_SESSION_CACHE_MS ?? 60000));
    return sessions;
  }

  private controllerFor(sessionId: string): BridgeController {
    const existing = this.controllers.get(sessionId);
    if (existing) {
      return existing;
    }
    const controller = new BridgeController({ profile: `fleet:${sessionId}`, appServer: workerAppServerOptions(this.options) });
    controller.on("bridgeNotification", (notification) => {
      this.reportNotification(sessionId, notification).catch((error) => this.reportAgentError(error));
    });
    this.controllers.set(sessionId, controller);
    return controller;
  }

  private rememberTask(command: FleetCommand, sessionId: string): void {
    const taskId = command.task_id ?? stringValue(command.payload.task_id);
    if (taskId) {
      this.taskBySession.set(sessionId, taskId);
    }
  }

  private watchVscodeRollout(command: FleetCommand, session: FleetSession | undefined): AbortController | undefined {
    const rolloutPath = stringValue(session?.rolloutPath);
    const taskId = command.task_id ?? stringValue(command.payload.task_id);
    const sessionId = session?.id ?? stringValue(command.payload.session_id);
    if (!rolloutPath || !sessionId) {
      this.manager.postEvents({
        events: [event(command, "task/error", "VS Code session has no rollout path; cannot read Codex final output", {
          session_id: sessionId,
          rollout_path: rolloutPath
        })]
      }).catch((error) => this.reportAgentError(error));
      return undefined;
    }

    const abort = new AbortController();
    this.rolloutWatches.add(abort);
    watchRolloutTask({
      rolloutPath,
      threadId: sessionId,
      timeoutMs: Number(process.env.CODEX_FLEET_ROLLOUT_TIMEOUT_MS ?? 30 * 60 * 1000),
      signal: abort.signal,
      onEvent: async (rolloutEvent) => {
        await this.reportRolloutEvent(command, rolloutEvent);
      }
    }).then((result) => {
      this.rolloutWatches.delete(abort);
      if (abort.signal.aborted) {
        return;
      }
      this.manager.postEvents({
        command_results: taskId ? [{
          command_id: `rollout-${sessionId}`,
          task_id: taskId,
          session_id: sessionId,
          ok: result.completed,
          task_status: result.completed ? "completed" : "error",
          summary: result.completed ? (result.finalText ?? "VS Code Codex task completed") : "VS Code Codex rollout monitor timed out before task_complete"
        }] : [],
        events: [{
          task_id: taskId,
          session_id: sessionId,
          type: result.completed ? "task/completed" : "task/error",
          message: result.completed ? (result.finalText ?? "VS Code Codex task completed") : "VS Code Codex rollout monitor timed out before task_complete",
          data: result
        }]
      }).catch((error) => this.reportAgentError(error));
      this.taskBySession.delete(sessionId);
    }).catch((error) => {
      this.rolloutWatches.delete(abort);
      this.taskBySession.delete(sessionId);
      this.manager.postEvents({
        command_results: taskId ? [this.fail(command, `rollout monitor failed: ${errorMessage(error)}`)] : [],
        events: [event(command, "task/error", `rollout monitor failed: ${errorMessage(error)}`, { session_id: sessionId, rollout_path: rolloutPath })]
      }).catch((postError) => this.reportAgentError(postError));
    });
    return abort;
  }

  private async ensureSessionMirrors(sessions: FleetSession[]): Promise<void> {
    if (isDisabled(process.env.CODEX_FLEET_MIRROR_FEISHU)) {
      for (const watch of this.sessionMirrorWatches.values()) {
        watch.abort();
      }
      this.sessionMirrorWatches.clear();
      return;
    }

    let bindings;
    try {
      bindings = await this.manager.chatBindings();
    } catch (error) {
      this.reportAgentError(error);
      return;
    }

    const bound = new Set(
      bindings
        .filter((binding) => isFeishuChannel(binding.channel))
        .map((binding) => stringValue(binding.session_id))
        .filter((sessionId): sessionId is string => Boolean(sessionId))
    );
    const maxMirrors = Math.max(1, Number(process.env.CODEX_FLEET_MIRROR_MAX_SESSIONS ?? 8));
    const wanted = new Set(
      sessions
        .filter((session) => bound.has(session.id) && session.source === "vscode" && stringValue(session.rolloutPath))
        .slice(0, maxMirrors)
        .map((session) => session.id)
    );

    for (const [sessionId, watch] of this.sessionMirrorWatches) {
      if (!wanted.has(sessionId)) {
        watch.abort();
        this.sessionMirrorWatches.delete(sessionId);
      }
    }

    for (const session of sessions) {
      if (!wanted.has(session.id) || this.sessionMirrorWatches.has(session.id)) {
        continue;
      }
      if (session.source !== "vscode" || !stringValue(session.rolloutPath)) {
        continue;
      }
      this.startSessionMirror(session);
    }
  }

  private startSessionMirror(session: FleetSession): void {
    const rolloutPath = stringValue(session.rolloutPath);
    if (!rolloutPath) {
      return;
    }
    const abort = new AbortController();
    this.sessionMirrorWatches.set(session.id, abort);
    watchRolloutTask({
      rolloutPath,
      threadId: session.id,
      timeoutMs: 0,
      pollMs: Math.max(500, Number(process.env.CODEX_FLEET_MIRROR_POLL_MS ?? 1000)),
      completeOnTaskComplete: false,
      signal: abort.signal,
      onEvent: async (rolloutEvent) => {
        await this.reportMirroredRolloutEvent(rolloutEvent);
      }
    }).catch((error) => {
      if (!abort.signal.aborted) {
        this.reportAgentError(error);
      }
    }).finally(() => {
      if (this.sessionMirrorWatches.get(session.id) === abort) {
        this.sessionMirrorWatches.delete(session.id);
      }
    });
  }

  private async reportMirroredRolloutEvent(rolloutEvent: RolloutTaskEvent): Promise<void> {
    if (this.taskBySession.has(rolloutEvent.threadId)) {
      return;
    }
    const text = rolloutEvent.text?.trim();
    if (!text || (rolloutEvent.kind !== "user_input" && rolloutEvent.kind !== "codex_reply" && rolloutEvent.kind !== "final_answer")) {
      return;
    }
    if (this.isRecentlyReportedTaskRolloutEvent(rolloutEvent, text)) {
      return;
    }
    const typeByKind: Record<"user_input" | "codex_reply" | "final_answer", string> = {
      user_input: "vscode/user",
      codex_reply: "vscode/assistant",
      final_answer: "vscode/final"
    };
    await this.manager.postEvents({
      events: [{
        session_id: rolloutEvent.threadId,
        type: typeByKind[rolloutEvent.kind],
        message: text,
        data: {
          ...rolloutEvent,
          mirrored: true
        }
      }]
    });
  }

  private async reportRolloutEvent(command: FleetCommand, rolloutEvent: RolloutTaskEvent): Promise<void> {
    this.rememberTaskRolloutEvent(rolloutEvent);
    const typeByKind: Record<RolloutTaskEvent["kind"], string> = {
      user_input: "vscode/user",
      codex_reply: "vscode/assistant",
      final_answer: "task/final",
      task_started: "turn/started",
      task_complete: "turn/completed"
    };
    await this.manager.postEvents({
      events: [{
        task_id: command.task_id ?? stringValue(command.payload.task_id),
        session_id: rolloutEvent.threadId,
        type: typeByKind[rolloutEvent.kind],
        message: rolloutEvent.text || rolloutEvent.kind,
        data: rolloutEvent
      }]
    });
  }

  private async reportNotification(sessionId: string, notification: { method: string; params?: unknown }): Promise<void> {
    const taskId = this.taskBySession.get(sessionId);
    const type = notification.method;
    const message = type === "turn/completed" ? "turn completed" : type === "turn/aborted" ? "turn aborted" : type;
    await this.manager.postEvents({
      events: [{
        task_id: taskId,
        session_id: sessionId,
        type,
        message,
        data: notification.params
      }],
      sessions: await this.discoverSessions()
    });
  }

  private startHeadless(command: FleetCommand, prompt: string): string {
    const taskId = command.task_id ?? stringValue(command.payload.task_id);
    const project = objectValue(command.payload.project);
    const cwd = stringValue(project?.path) || process.cwd();
    const sessionId = `headless-${taskId ?? Date.now()}`;
    const child = spawn("codex", ["exec", "--json", "--skip-git-repo-check", "-C", cwd, prompt], {
      stdio: ["ignore", "pipe", "pipe"],
      env: codexChildEnv()
    });
    const run: HeadlessRun = { taskId, sessionId, process: child, mode: "headless" };
    this.trackHeadlessRun(run);
    return sessionId;
  }

  private trackHeadlessRun(run: HeadlessRun): void {
    if (run.taskId) {
      this.headlessRuns.set(run.taskId, run);
      this.taskBySession.set(run.sessionId, run.taskId);
    }
    this.streamHeadless(run);
  }

  private streamHeadless(run: HeadlessRun): void {
    const timeoutMs = Number(process.env.CODEX_FLEET_HEADLESS_TIMEOUT_MS ?? 180000);
    const timeout = Number.isFinite(timeoutMs) && timeoutMs > 0
      ? setTimeout(() => {
          run.timedOut = true;
          run.process.kill("SIGTERM");
        }, timeoutMs)
      : undefined;

    if (run.process.stdout) {
      const stdout = readline.createInterface({ input: run.process.stdout, crlfDelay: Infinity });
      stdout.on("line", (line) => {
        const parsed = parseJsonLine(line);
        const agentText = agentMessageText(parsed);
        if (agentText) {
          run.finalText = agentText;
        }
        this.manager.postEvents({
          events: [{
            task_id: run.taskId,
            session_id: run.sessionId,
            type: agentText ? "task/final" : "headless/stdout",
            message: line.slice(0, 500),
            data: parsed
          }]
        }).catch((error) => this.reportAgentError(error));
      });
    }
    if (run.process.stderr) {
      const stderr = readline.createInterface({ input: run.process.stderr, crlfDelay: Infinity });
      stderr.on("line", (line) => {
        this.manager.postEvents({
          events: [{
            task_id: run.taskId,
            session_id: run.sessionId,
            type: "headless/stderr",
            message: line.slice(0, 500)
          }]
        }).catch((error) => this.reportAgentError(error));
      });
    }
    run.process.on("exit", (code, signal) => {
      if (timeout) {
        clearTimeout(timeout);
      }
      if (run.taskId) {
        this.headlessRuns.delete(run.taskId);
      }
      this.taskBySession.delete(run.sessionId);
      const ok = code === 0 && !run.timedOut;
      const failureMessage = run.timedOut
        ? `${run.mode} task timed out after ${timeoutMs}ms`
        : `${run.mode} task exited code=${code} signal=${signal ?? ""}`.trim();
      this.manager.postEvents({
        command_results: run.taskId ? [{
          command_id: `exit-${run.sessionId}`,
          task_id: run.taskId,
          session_id: run.sessionId,
          ok,
          task_status: ok ? "completed" : "error",
          summary: ok ? (run.finalText ?? `${run.mode} task completed`) : failureMessage
        }] : [],
        events: [{
          task_id: run.taskId,
          session_id: run.sessionId,
          type: ok ? "task/completed" : "task/error",
          message: ok ? (run.finalText ?? `${run.mode} task completed`) : failureMessage
        }]
      }).catch((error) => this.reportAgentError(error));
    });
  }

  private ok(command: FleetCommand, sessionId: string | undefined | null, taskStatus: string, summary: string): FleetCommandResult {
    return {
      command_id: command.command_id,
      task_id: command.task_id,
      session_id: sessionId,
      ok: true,
      task_status: taskStatus,
      summary
    };
  }

  private fail(command: FleetCommand, error: string): FleetCommandResult {
    return {
      command_id: command.command_id,
      task_id: command.task_id,
      ok: false,
      task_status: "error",
      error,
      summary: error
    };
  }

  private reportAgentError(error: unknown): void {
    process.stderr.write(`worker agent error: ${errorMessage(error)}\n`);
  }

  private rememberTaskRolloutEvent(event: RolloutTaskEvent): void {
    const text = event.text?.trim();
    if (!text || (event.kind !== "user_input" && event.kind !== "final_answer")) {
      return;
    }
    this.recentTaskMirrorSuppressions.set(taskMirrorSuppressionKey(event.threadId, event.kind, text), Date.now() + 120000);
  }

  private isRecentlyReportedTaskRolloutEvent(event: RolloutTaskEvent, text: string): boolean {
    const now = Date.now();
    for (const [key, expiresAt] of this.recentTaskMirrorSuppressions) {
      if (expiresAt <= now) {
        this.recentTaskMirrorSuppressions.delete(key);
      }
    }
    return (this.recentTaskMirrorSuppressions.get(taskMirrorSuppressionKey(event.threadId, event.kind, text)) ?? 0) > now;
  }
}

export function threadToFleetSession(thread: ThreadSummary): FleetSession {
  return {
    id: thread.id,
    source: thread.source ?? "vscode",
    title: thread.title ?? thread.name ?? thread.preview ?? null,
    cwd: thread.cwd ?? null,
    rolloutPath: stringValue((thread as ThreadSummary & { rolloutPath?: unknown; rollout_path?: unknown }).rolloutPath)
      ?? stringValue((thread as ThreadSummary & { rolloutPath?: unknown; rollout_path?: unknown }).rollout_path)
      ?? stringValue(thread.path)
      ?? null
  };
}

export function shouldUseVscodeIpcForSession(session: FleetSession | undefined): boolean {
  return !session || session.source === "vscode";
}

export function workerAppServerOptions(options: Pick<WorkerAgentOptions, "appServerUrl" | "appServerSocketPath">): AppServerClientOptions | undefined {
  if (!options.appServerUrl && !options.appServerSocketPath) {
    return undefined;
  }
  if (options.appServerSocketPath && !options.appServerUrl) {
    return {
      appServerUrl: `unix://${options.appServerSocketPath}`,
      socketPath: options.appServerSocketPath
    };
  }
  return {
    appServerUrl: options.appServerUrl,
    socketPath: options.appServerSocketPath
  };
}

function event(command: FleetCommand, type: string, message: string, data?: unknown): FleetEvent {
  return {
    task_id: command.task_id ?? stringValue(command.payload.task_id),
    session_id: stringValue(command.payload.session_id),
    type,
    message,
    data
  };
}

function codexChildEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env.CODEX_THREAD_ID;
  delete env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
  return env;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function objectValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function parseJsonLine(line: string): unknown {
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
}

function agentMessageText(value: unknown): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const item = record.item;
  if (!item || typeof item !== "object") {
    return undefined;
  }
  const itemRecord = item as Record<string, unknown>;
  if (itemRecord.type !== "agent_message") {
    return undefined;
  }
  return stringValue(itemRecord.text);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function formatSendMode(result: { mode: string; transport?: string }): string {
  return result.transport ? `${result.transport} ${result.mode}` : result.mode;
}

function taskMirrorSuppressionKey(threadId: string, kind: RolloutTaskEvent["kind"], text: string): string {
  return JSON.stringify([threadId, kind, text]);
}

function isFeishuChannel(value: unknown): boolean {
  const channel = String(value ?? "").trim().toLowerCase();
  return channel === "feishu" || channel.endsWith("feishu");
}

function isDisabled(value: unknown): boolean {
  return /^(0|false|off|no)$/i.test(String(value ?? "").trim());
}
