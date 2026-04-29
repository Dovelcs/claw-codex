export type BridgeCommand =
  | { type: "vscode-list" }
  | { type: "vscode-use"; selector: string }
  | { type: "vscode-status" }
  | { type: "stop" }
  | { type: "send"; text: string };

export function parseBridgeCommand(input: string): BridgeCommand {
  const trimmed = input.trim();
  if (!trimmed) {
    throw new Error("empty command");
  }

  if (trimmed === "/stop" || trimmed === "stop") {
    return { type: "stop" };
  }

  if (trimmed === "/status" || trimmed === "status") {
    return { type: "vscode-status" };
  }

  const vscodeMatch = trimmed.match(/^\/?vscode(?:\s+(.+))?$/);
  if (vscodeMatch) {
    const rest = vscodeMatch[1]?.trim() ?? "list";
    if (rest === "list") {
      return { type: "vscode-list" };
    }
    if (rest === "status") {
      return { type: "vscode-status" };
    }
    const useMatch = rest.match(/^use\s+(.+)$/);
    if (useMatch) {
      return { type: "vscode-use", selector: useMatch[1].trim() };
    }
    throw new Error(`unsupported vscode command: ${rest}`);
  }

  return { type: "send", text: input };
}
