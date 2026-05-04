#!/bin/sh
set -eu

LOG="${CODEX_FLEET_AUTOSTART_LOG:-/tmp/codex-fleet-autostart.log}"
CONTAINER="${CODEX_OPENCLAW_CONTAINER:-openclaw-gateway-v2}"
FLEET_DIR="${CODEX_FLEET_DIR:-/opt/weixin-bot/codex-fleet}"
FLEET_DB="${CODEX_FLEET_DB:-/opt/weixin-bot/data/codex-fleet/fleet.db}"
FLEET_HOST="${CODEX_FLEET_HOST:-100.106.225.53}"
FLEET_PORT="${CODEX_FLEET_PORT:-18992}"
FLEET_LOG="${CODEX_FLEET_LOG:-/opt/weixin-bot/data/codex-fleet/fleet-manager.log}"
FLEET_HOST_WAIT_SECONDS="${CODEX_FLEET_HOST_WAIT_SECONDS:-120}"

ts() {
  date -Is
}

log() {
  printf '%s %s\n' "$(ts)" "$*" >> "$LOG"
}

start_docker() {
  if [ -x /etc/init.d/dockerd ]; then
    /etc/init.d/dockerd enable >/dev/null 2>&1 || true
    /etc/init.d/dockerd start >/dev/null 2>&1 || true
  fi
}

start_container() {
  docker update --restart unless-stopped "$CONTAINER" >/dev/null 2>&1 || true
  docker start "$CONTAINER" >/dev/null 2>&1 || true
}

fleet_manager_running() {
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr "\000" " " < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *"python3 fleet_manager/codex_fleet_manager.py"*|*"python3 /opt/weixin-bot/codex-fleet/fleet_manager/codex_fleet_manager.py"*)
        return 0
        ;;
    esac
  done
  return 1
}

fleet_host_needs_local_addr() {
  case "$FLEET_HOST" in
    ""|"0.0.0.0"|"127.0.0.1"|"localhost")
      return 1
      ;;
  esac
  return 0
}

wait_fleet_host_addr() {
  fleet_host_needs_local_addr || return 0
  waited=0
  while ! ip -4 addr show 2>/dev/null | grep -q "inet ${FLEET_HOST}/"; do
    if [ "$waited" -ge "$FLEET_HOST_WAIT_SECONDS" ]; then
      log "fleet host address not available after ${waited}s: $FLEET_HOST"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$waited" -gt 0 ]; then
    log "fleet host address ready after ${waited}s: $FLEET_HOST"
  fi
}

start_fleet_manager() {
  if fleet_manager_running; then
    log "fleet manager already running"
    return 0
  fi
  if [ ! -d "$FLEET_DIR" ]; then
    log "fleet dir missing: $FLEET_DIR"
    return 0
  fi
  wait_fleet_host_addr || return 0
  mkdir -p "$(dirname "$FLEET_DB")"
  (
    cd "$FLEET_DIR"
    nohup python3 fleet_manager/codex_fleet_manager.py --host "$FLEET_HOST" --port "$FLEET_PORT" --db "$FLEET_DB" >> "$FLEET_LOG" 2>&1 < /dev/null &
  )
  log "started fleet manager"
}

start_container_services() {
  docker exec "$CONTAINER" sh -lc '
set -eu
bridge_running=0
auto_groups_running=0
for p in /proc/[0-9]*; do
  [ "${p#/proc/}" = "$$" ] && continue
  cmd=$(tr "\000" " " < "$p/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *"python3 /data/state/codex-bridge/package/server/codex_bridge_server.py"*) bridge_running=1 ;;
    *"/data/state/codex-bridge/scripts/feishu_auto_session_groups.sh"*) auto_groups_running=1 ;;
  esac
done
if [ "$bridge_running" = "0" ]; then
  nohup python3 /data/state/codex-bridge/package/server/codex_bridge_server.py --listen 127.0.0.1 --port 18991 >>/data/state/codex-bridge/server.out 2>&1 < /dev/null &
  echo started bridge
fi
if [ -x /data/state/codex-bridge/scripts/feishu_auto_session_groups.sh ] && [ "$auto_groups_running" = "0" ]; then
  nohup /data/state/codex-bridge/scripts/feishu_auto_session_groups.sh >>/data/state/codex-bridge/feishu-auto-session-groups.out 2>&1 < /dev/null &
  echo $! >/data/state/codex-bridge/feishu-auto-session-groups.pid
  echo started feishu auto session groups
fi
' >> "$LOG" 2>&1 || log "container service start failed"
}

main() {
  log "autostart begin"
  start_docker
  start_container
  start_fleet_manager
  start_container_services
  log "autostart done"
}

main "$@"
