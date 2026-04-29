#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const MANAGER_URL = process.env.CODEX_FLEET_URL || "http://127.0.0.1:18992";
const TOKEN = process.env.CODEX_FLEET_TOKEN || "";
const PROFILE = process.env.CODEX_FLEET_PROFILE || "home-codex";

const tools = [
  tool("fleet_status", "Show endpoint, project, session, and task state.", {}),
  tool("fleet_summary", "Show compact active task and target summary for WeChat reporting.", {
    limit: { type: "number" }
  }),
  tool("fleet_list_projects", "List registered project aliases.", {}),
  tool("fleet_list_sessions", "List company Codex sessions.", {
    endpoint: { type: "string" },
    project: { type: "string" }
  }),
  tool("fleet_use_project", "Set the current project for this home Codex profile.", {
    project_alias: { type: "string" }
  }, ["project_alias"]),
  tool("fleet_use_session", "Set the current VS Code/headless session for this home Codex profile.", {
    session_selector: { type: "string" }
  }, ["session_selector"]),
  tool("fleet_clear_target", "Clear the current company project/session target and return to home Codex handling.", {}),
  tool("fleet_start_task", "Start a company Codex task.", {
    prompt: { type: "string" },
    project_alias: { type: "string" },
    session_selector: { type: "string" },
    mode: { type: "string", enum: ["vscode", "headless"] }
  }, ["prompt"]),
  tool("fleet_send", "Send follow-up text to the current bound session.", {
    text: { type: "string" }
  }, ["text"]),
  tool("fleet_stop", "Stop a task or session.", {
    target: { type: "string" }
  }, ["target"]),
  tool("fleet_read", "Read task/session events.", {
    target: { type: "string" },
    tail: { type: "number" }
  }),
  tool("fleet_register_project", "Register or update a project alias.", {
    alias: { type: "string" },
    endpoint_id: { type: "string" },
    path: { type: "string" },
    mode: { type: "string", enum: ["vscode", "headless"] }
  }, ["alias", "endpoint_id", "path"]),
  tool("fleet_bind_chat", "Bind a chat window to a project alias.", {
    channel: { type: "string" },
    chat_id: { type: "string" },
    project_alias: { type: "string" },
    profile: { type: "string" },
    endpoint_id: { type: "string" },
    session_policy: { type: "string" }
  }, ["channel", "chat_id", "project_alias"]),
  tool("fleet_unbind_chat", "Remove a chat window project binding.", {
    channel: { type: "string" },
    chat_id: { type: "string" }
  }, ["channel", "chat_id"]),
  tool("fleet_chat_status", "Read one chat window binding and active task status.", {
    channel: { type: "string" },
    chat_id: { type: "string" }
  }, ["channel", "chat_id"])
];

function tool(name, description, properties, required = []) {
  return {
    name,
    description,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties,
      required
    }
  };
}

async function manager(path, options = {}) {
  const response = await fetch(`${MANAGER_URL}${path}`, {
    ...options,
    headers: {
      "content-type": "application/json",
      ...(TOKEN ? { authorization: `Bearer ${TOKEN}` } : {}),
      ...(options.headers || {})
    }
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`fleet manager HTTP ${response.status}: ${text}`);
  }
  return payload;
}

function query(params) {
  const qs = new URLSearchParams();
  for (const [key, value] of Object.entries(params || {})) {
    if (value !== undefined && value !== null && value !== "") qs.set(key, String(value));
  }
  const text = qs.toString();
  return text ? `?${text}` : "";
}

async function callFleetTool(name, args) {
  if (name === "fleet_status") return manager("/api/state");
  if (name === "fleet_summary") return manager(`/api/summary${query({ profile: PROFILE, limit: args.limit || 10 })}`);
  if (name === "fleet_list_projects") return manager("/api/projects");
  if (name === "fleet_list_sessions") return manager(`/api/sessions${query({ endpoint: args.endpoint, project: args.project })}`);
  if (name === "fleet_use_project") return manager("/api/context/project", { method: "POST", body: JSON.stringify({ profile: PROFILE, project_alias: args.project_alias }) });
  if (name === "fleet_use_session") return manager("/api/context/session", { method: "POST", body: JSON.stringify({ profile: PROFILE, session_selector: args.session_selector }) });
  if (name === "fleet_clear_target") return manager("/api/context/clear", { method: "POST", body: JSON.stringify({ profile: PROFILE }) });
  if (name === "fleet_start_task") return manager("/api/tasks", { method: "POST", body: JSON.stringify({ profile: PROFILE, prompt: args.prompt, project_alias: args.project_alias, session_selector: args.session_selector, mode: args.mode }) });
  if (name === "fleet_send") return manager("/api/tasks", { method: "POST", body: JSON.stringify({ profile: PROFILE, prompt: args.text }) });
  if (name === "fleet_stop") return manager("/api/stop", { method: "POST", body: JSON.stringify({ target: args.target }) });
  if (name === "fleet_read") return manager(`/api/events${query({ target: args.target, tail: args.tail || 20 })}`);
  if (name === "fleet_register_project") return manager("/api/projects", { method: "POST", body: JSON.stringify({ alias: args.alias, endpoint_id: args.endpoint_id, path: args.path, mode: args.mode || "vscode" }) });
  if (name === "fleet_bind_chat") return manager("/api/chat-bindings", { method: "POST", body: JSON.stringify({ channel: args.channel, chat_id: args.chat_id, project_alias: args.project_alias, profile: args.profile, endpoint_id: args.endpoint_id, session_policy: args.session_policy || "project-default" }) });
  if (name === "fleet_unbind_chat") return manager("/api/chat-bindings/clear", { method: "POST", body: JSON.stringify({ channel: args.channel, chat_id: args.chat_id }) });
  if (name === "fleet_chat_status") return manager(`/api/chat-bindings${query({ channel: args.channel, chat_id: args.chat_id })}`);
  throw new Error(`unknown fleet tool: ${name}`);
}

const server = new Server({ name: "codex-fleet", version: "0.1.0" }, { capabilities: { tools: {} } });

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;
  try {
    const result = await callFleetTool(name, args);
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  } catch (error) {
    return { isError: true, content: [{ type: "text", text: String(error?.stack || error) }] };
  }
});

await server.connect(new StdioServerTransport());
