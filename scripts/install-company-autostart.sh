#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${CODEX_BRIDGE_STATE_DIR:-/home/donovan/.codex-bridge}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
CRON_MARK_BEGIN="# BEGIN CODEX FLEET AUTOSTART"
CRON_MARK_END="# END CODEX FLEET AUTOSTART"

mkdir -p "$STATE_DIR" "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/codex-fleet-agent-watchdog.service" <<EOF
[Unit]
Description=Codex Fleet Agent Watchdog
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=CODEX_BRIDGE_STATE_DIR=$STATE_DIR
ExecStart=$REPO_DIR/scripts/start-fleet-agent-watchdog.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

cat > "$SYSTEMD_USER_DIR/codex-fleet-log-monitor.service" <<EOF
[Unit]
Description=Codex Fleet Log Monitor
After=network-online.target codex-fleet-agent-watchdog.service

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=CODEX_BRIDGE_STATE_DIR=$STATE_DIR
ExecStart=$REPO_DIR/scripts/start-codex-fleet-log-monitor.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable --now codex-fleet-agent-watchdog.service codex-fleet-log-monitor.service
fi

tmp_cron="$(mktemp)"
if crontab -l > "$tmp_cron" 2>/dev/null; then
  sed -i "/^$CRON_MARK_BEGIN\$/,/^$CRON_MARK_END\$/d" "$tmp_cron"
else
  : > "$tmp_cron"
fi

cat >> "$tmp_cron" <<EOF
$CRON_MARK_BEGIN
@reboot /bin/bash -lc 'cd "$REPO_DIR" && CODEX_BRIDGE_STATE_DIR="$STATE_DIR" "$REPO_DIR/scripts/start-fleet-agent-watchdog.sh" >> "$STATE_DIR/autostart.log" 2>&1'
@reboot /bin/bash -lc 'cd "$REPO_DIR" && CODEX_BRIDGE_STATE_DIR="$STATE_DIR" "$REPO_DIR/scripts/start-codex-fleet-log-monitor.sh" >> "$STATE_DIR/autostart.log" 2>&1'
$CRON_MARK_END
EOF
crontab "$tmp_cron"
rm -f "$tmp_cron"

CODEX_BRIDGE_STATE_DIR="$STATE_DIR" "$REPO_DIR/scripts/start-fleet-agent-watchdog.sh"
CODEX_BRIDGE_STATE_DIR="$STATE_DIR" "$REPO_DIR/scripts/start-codex-fleet-log-monitor.sh"

printf 'installed company autostart repo=%s state=%s\n' "$REPO_DIR" "$STATE_DIR"
