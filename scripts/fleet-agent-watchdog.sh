#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${CODEX_BRIDGE_STATE_DIR:-/home/donovan/.codex-bridge}"
PID_FILE="$STATE_DIR/fleet-agent.pid"
WATCHDOG_PID_FILE="$STATE_DIR/fleet-agent-watchdog.pid"
RUNNER="$STATE_DIR/run-fleet-agent.sh"
LOG_FILE="$STATE_DIR/fleet-agent.log"
WATCHDOG_LOG="$STATE_DIR/fleet-agent-watchdog.log"
INTERVAL="${CODEX_FLEET_WATCHDOG_INTERVAL:-10}"

mkdir -p "$STATE_DIR"

ts() {
  date -Is
}

alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start_worker() {
  nohup "$RUNNER" >> "$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  printf '%s restarted worker pid=%s\n' "$(ts)" "$(<"$PID_FILE")" >> "$WATCHDOG_LOG"
}

echo "$$" > "$WATCHDOG_PID_FILE"
printf '%s watchdog started interval=%ss\n' "$(ts)" "$INTERVAL" >> "$WATCHDOG_LOG"

trap 'rm -f "$WATCHDOG_PID_FILE"; exit 0' INT TERM EXIT

while true; do
  pid=""
  [[ -f "$PID_FILE" ]] && pid="$(<"$PID_FILE")"
  if ! alive "$pid"; then
    start_worker
  fi
  sleep "$INTERVAL"
done
