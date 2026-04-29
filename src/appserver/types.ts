export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

export type RequestId = string | number;

export interface JsonRpcRequest {
  id: RequestId;
  method: string;
  params?: unknown;
}

export interface JsonRpcResponse {
  id: RequestId;
  result?: unknown;
  error?: {
    code?: number;
    message?: string;
    data?: unknown;
  };
}

export interface JsonRpcNotification {
  method: string;
  params?: unknown;
}

export interface TextUserInput {
  type: "text";
  text: string;
  text_elements?: unknown[];
}

export interface ThreadSummary {
  id: string;
  title?: string | null;
  name?: string | null;
  preview?: string | null;
  cwd?: string | null;
  source?: string | null;
  updatedAt?: string | number | null;
  createdAt?: string | number | null;
  status?: unknown;
  model?: string | null;
  path?: string | null;
  rolloutPath?: string | null;
  rollout_path?: string | null;
}

export interface ThreadListResponse {
  data?: ThreadSummary[];
  threads?: ThreadSummary[];
  nextCursor?: string | null;
  backwardsCursor?: string | null;
}

export interface ThreadReadResponse {
  thread?: unknown;
}

export interface StartOrSteerResult {
  mode: "start" | "steer" | "queued";
  transport?: "vscode-ipc";
  response?: unknown;
  turnId?: string;
}
