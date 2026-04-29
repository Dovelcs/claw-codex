#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${CODEX_BRIDGE_STATE_DIR:-/home/donovan/.codex-bridge}"
WATCHDOG="$PWD/scripts/fleet-agent-watchdog.sh"
WATCHDOG_PID_FILE="$STATE_DIR/fleet-agent-watchdog.pid"
WATCHDOG_OUT="$STATE_DIR/fleet-agent-watchdog.out"

mkdir -p "$STATE_DIR"

alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

pid=""
[[ -f "$WATCHDOG_PID_FILE" ]] && pid="$(<"$WATCHDOG_PID_FILE")"
if alive "$pid"; then
  printf 'watchdog already running pid=%s\n' "$pid"
  exit 0
fi

rm -f "$WATCHDOG_PID_FILE"
nohup setsid "$WATCHDOG" > "$WATCHDOG_OUT" 2>&1 < /dev/null &
printf 'watchdog start requested launcher_pid=%s\n' "$!"
