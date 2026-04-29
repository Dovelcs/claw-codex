#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${CODEX_FLEET_REPO_DIR:-/home/donovan/samba/codex-server}"
STATE_DIR="${CODEX_BRIDGE_STATE_DIR:-/home/donovan/.codex-bridge}"
ENV_FILE="$STATE_DIR/fleet-agent.env"
MONITOR_LOG="$STATE_DIR/codex-fleet-monitor.log"
CODEX_AUDIT_LOG="$STATE_DIR/codex-fleet-monitor-codex.jsonl"
PID_FILE="$STATE_DIR/codex-fleet-log-monitor.pid"
INTERVAL="${CODEX_FLEET_MONITOR_INTERVAL:-30}"
ANOMALY_COOLDOWN="${CODEX_FLEET_MONITOR_CODEX_COOLDOWN:-600}"
QUEUE_STALE_SECONDS="${CODEX_FLEET_QUEUE_STALE_SECONDS:-180}"
RUNNING_STALE_SECONDS="${CODEX_FLEET_RUNNING_STALE_SECONDS:-900}"

mkdir -p "$STATE_DIR"
cd "$REPO_DIR"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

MANAGER_URL="${CODEX_FLEET_URL:-http://127.0.0.1:18992}"
AUTH_HEADER=()
if [[ -n "${CODEX_FLEET_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${CODEX_FLEET_TOKEN}")
fi

echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"; exit 0' INT TERM EXIT

ts() {
  date -Is
}

alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

log() {
  printf '%s %s\n' "$(ts)" "$*" >> "$MONITOR_LOG"
}

start_watchdog() {
  CODEX_BRIDGE_STATE_DIR="$STATE_DIR" "$REPO_DIR/scripts/start-fleet-agent-watchdog.sh" >> "$MONITOR_LOG" 2>&1 || true
}

manager_json() {
  curl -fsS --max-time 8 "${AUTH_HEADER[@]}" "$MANAGER_URL$1"
}

detect_state_anomaly() {
  local endpoints_json="$1"
  local tasks_json="$2"
  ENDPOINTS_JSON="$endpoints_json" TASKS_JSON="$tasks_json" QUEUE_STALE_SECONDS="$QUEUE_STALE_SECONDS" RUNNING_STALE_SECONDS="$RUNNING_STALE_SECONDS" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone

endpoints_payload = json.loads(os.environ["ENDPOINTS_JSON"])
tasks_payload = json.loads(os.environ["TASKS_JSON"])
now = datetime.now(timezone.utc)
queue_stale = int(os.environ["QUEUE_STALE_SECONDS"])
running_stale = int(os.environ["RUNNING_STALE_SECONDS"])
reasons = []

for endpoint in endpoints_payload.get("endpoints", []):
    if endpoint.get("status") != "online":
        reasons.append(f"endpoint {endpoint.get('endpoint_id')} status={endpoint.get('status')}")

for task in tasks_payload.get("tasks", []):
    status = task.get("status")
    updated = task.get("updated_at") or task.get("created_at")
    if not updated:
        continue
    try:
        dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
    except ValueError:
        continue
    age = max(0, int((now - dt).total_seconds()))
    if status == "queued" and age >= queue_stale:
        reasons.append(f"task {task.get('task_id')} queued age={age}s")
    if status == "running" and age >= running_stale:
        reasons.append(f"task {task.get('task_id')} running age={age}s")

print("\n".join(reasons))
PY
}

run_codex_audit() {
  local reason="$1"
  local now_epoch last_epoch
  now_epoch="$(date +%s)"
  last_epoch="$(cat "$STATE_DIR/codex-fleet-monitor.last-codex" 2>/dev/null || echo 0)"
  if (( now_epoch - last_epoch < ANOMALY_COOLDOWN )); then
    return 0
  fi
  echo "$now_epoch" > "$STATE_DIR/codex-fleet-monitor.last-codex"
  {
    printf 'Fleet monitor anomaly detected at %s\n' "$(ts)"
    printf 'Reason:\n%s\n\n' "$reason"
    printf 'Recent watchdog log:\n'
    tail -n 80 "$STATE_DIR/fleet-agent-watchdog.log" 2>/dev/null || true
    printf '\nRecent worker log:\n'
    tail -n 120 "$STATE_DIR/fleet-agent.log" 2>/dev/null || true
    printf '\nRecent monitor log:\n'
    tail -n 80 "$MONITOR_LOG" 2>/dev/null || true
  } > "$STATE_DIR/codex-fleet-monitor.prompt"

  nohup codex exec --json --skip-git-repo-check -C "$REPO_DIR" \
    "只读取 /home/donovan/.codex-bridge/codex-fleet-monitor.prompt。禁止读取 memory，禁止搜索仓库，禁止修改文件。判断 codex fleet worker/manager 是否异常；如果需要恢复，只给出最小恢复动作建议。" \
    >> "$CODEX_AUDIT_LOG" 2>&1 < /dev/null &
  log "started codex audit pid=$! reason=$(echo "$reason" | tr '\n' ';' | cut -c1-240)"
}

log "monitor started interval=${INTERVAL}s manager=${MANAGER_URL}"

while true; do
  watchdog_pid="$(cat "$STATE_DIR/fleet-agent-watchdog.pid" 2>/dev/null || true)"
  if ! alive "$watchdog_pid"; then
    log "watchdog missing; starting"
    start_watchdog
  fi

  if endpoints_json="$(manager_json /api/endpoints 2>>"$MONITOR_LOG")" && tasks_json="$(manager_json /api/tasks 2>>"$MONITOR_LOG")"; then
    if reason="$(detect_state_anomaly "$endpoints_json" "$tasks_json")" && [[ -n "$reason" ]]; then
      log "state anomaly: $(echo "$reason" | tr '\n' ';' | cut -c1-240)"
      start_watchdog
      run_codex_audit "$reason"
    fi
  else
    log "manager compact status request failed"
    run_codex_audit "manager compact status request failed"
  fi

  sleep "$INTERVAL"
done
