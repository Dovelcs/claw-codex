export interface WorkerIncomingMessage {
  type?: "wechat.message";
  chatId: string;
  text: string;
}

export interface WorkerOutgoingMessage {
  type: "reply" | "error" | "threadList" | "bound" | "status" | "sent" | "stopped";
  chatId: string;
  text?: string;
  data?: unknown;
}
