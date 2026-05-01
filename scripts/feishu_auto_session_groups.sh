#!/bin/sh
set -eu

MANAGER="${CODEX_FLEET_MANAGER:-http://100.106.225.53:18992}"
CONFIG="${OPENCLAW_CONFIG:-/data/state/openclaw.json}"
SCRIPT="${FEISHU_PROVISION_SCRIPT:-/data/state/codex-bridge/scripts/feishu_provision_session_groups.py}"
STATE_FILE="${FEISHU_AUTO_SESSION_GROUPS_STATE:-/data/state/codex-bridge/feishu-auto-session-groups-state.json}"
INTERVAL="${FEISHU_AUTO_SESSION_GROUPS_INTERVAL:-10}"
LOG="${FEISHU_AUTO_SESSION_GROUPS_LOG:-/data/state/codex-bridge/feishu-auto-session-groups.log}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"

while :; do
  date -Is >> "$LOG"
  python3 "$SCRIPT" \
    --manager "$MANAGER" \
    --config "$CONFIG" \
    --new-sessions-only \
    --state-file "$STATE_FILE" \
    --no-intro >> "$LOG" 2>&1 || true
  sleep "$INTERVAL"
done
