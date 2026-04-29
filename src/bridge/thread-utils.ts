import { extractTurnId } from "../appserver/client.js";

export function extractStatus(value: unknown): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const status = record.status;
  if (typeof status === "string") {
    return status;
  }
  if (status && typeof status === "object") {
    const nested = status as Record<string, unknown>;
    for (const key of ["type", "state", "status"]) {
      if (typeof nested[key] === "string") {
        return nested[key] as string;
      }
    }
  }
  return undefined;
}

export function isRunningStatus(status: string | undefined): boolean {
  return status === "running" || status === "active" || status === "inProgress" || status === "pending";
}

export function extractActiveTurnId(thread: unknown): string | undefined {
  if (!thread || typeof thread !== "object") {
    return undefined;
  }
  const record = thread as Record<string, unknown>;

  for (const key of ["activeTurnId", "active_turn_id", "currentTurnId", "current_turn_id"]) {
    const value = record[key];
    if (typeof value === "string") {
      return value;
    }
  }

  const activeTurn = record.activeTurn ?? record.currentTurn;
  const fromActiveTurn = extractTurnId(activeTurn);
  if (fromActiveTurn) {
    return fromActiveTurn;
  }

  const turns = record.turns;
  if (!Array.isArray(turns)) {
    return undefined;
  }

  for (let index = turns.length - 1; index >= 0; index--) {
    const turn = turns[index];
    if (isRunningStatus(extractStatus(turn))) {
      return extractTurnId(turn);
    }
  }

  return undefined;
}
