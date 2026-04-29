#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${CODEX_BRIDGE_STATE_DIR:-/home/donovan/.codex-bridge}"
PID_FILE="$STATE_DIR/codex-fleet-log-monitor.pid"
OUT_FILE="$STATE_DIR/codex-fleet-log-monitor.out"
MONITOR="$PWD/scripts/codex-fleet-log-monitor.sh"

mkdir -p "$STATE_DIR"

alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

pid=""
[[ -f "$PID_FILE" ]] && pid="$(<"$PID_FILE")"
if alive "$pid"; then
  printf 'codex fleet log monitor already running pid=%s\n' "$pid"
  exit 0
fi

rm -f "$PID_FILE"
nohup setsid "$MONITOR" > "$OUT_FILE" 2>&1 < /dev/null &
printf 'codex fleet log monitor start requested launcher_pid=%s\n' "$!"
