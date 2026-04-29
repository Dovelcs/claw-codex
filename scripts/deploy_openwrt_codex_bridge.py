#!/usr/bin/env python3
"""Apply the complete OpenWrt codex bridge patch set in a fixed order.

Run this script on OpenWrt from a directory that also contains the
patch_openwrt_*.py scripts from this repository.
"""

from __future__ import annotations

import json
import os
import runpy
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


STATE = Path("/opt/weixin-bot/data/openclaw/state/codex-bridge")
CONTAINER_STATE = Path("/data/state/codex-bridge")
TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]
PATCH_ORDER = [
    "patch_openwrt_feishu_target_normalize.py",
    "patch_openwrt_outbound_queue.py",
    "patch_openwrt_feishu_output_format.py",
    "patch_openwrt_feishu_progress_edit.py",
    "patch_openwrt_feishu_guidance.py",
    "patch_openwrt_feishu_task_recovery.py",
    "patch_openwrt_feishu_session_progress.py",
    "patch_openwrt_feishu_group_only_routes.py",
    "patch_openwrt_channel_policy.py",
]
REQUIRED_MARKERS = [
    "def enqueue_outbound_message(",
    "def build_feishu_progress_card(",
    "def mark_task_final_notification(",
    "def clear_feishu_session_progress_mirror(",
    "def is_feishu_group_chat_id(",
    "if is_feishu_channel(channel) and not is_feishu_group_target(channel,chat_id,session_key):",
    "def is_company_fleet_channel(",
]


def run_patch(path: Path) -> None:
    print(f"apply {path.name}")
    runpy.run_path(str(path), run_name="__main__")


def py_compile(paths: list[Path]) -> None:
    subprocess.check_call([sys.executable, "-m", "py_compile", *map(str, paths)])


def verify_markers(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    missing = [marker for marker in REQUIRED_MARKERS if marker not in text]
    if missing:
        raise RuntimeError(f"{path} missing required markers: {missing}")


def clear_non_group_progress_bindings() -> None:
    for state_dir in (STATE, CONTAINER_STATE):
        state_path = state_dir / "fleet-feishu-session-mirror.json"
        if not state_path.exists():
            continue
        data = json.loads(state_path.read_text(encoding="utf-8"))
        progress = data.get("progress_messages") or {}
        kept = {k: v for k, v in progress.items() if str(k).startswith("oc_")}
        removed = sorted(set(progress) - set(kept))
        if removed:
            data["progress_messages"] = kept
            data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            state_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(f"removed non-group progress bindings from {state_path}: {len(removed)}")


def restart_bridge() -> None:
    try:
        out = subprocess.check_output("docker exec openclaw-gateway-v2 sh -lc 'ps w || ps'", shell=True, text=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"cannot list bridge processes: {exc}") from exc
    for line in out.splitlines():
        if "codex_bridge_server.py" not in line or "grep" in line:
            continue
        fields = line.split()
        if not fields:
            continue
        subprocess.run(
            f"docker exec openclaw-gateway-v2 sh -lc 'kill -TERM {fields[0]}'",
            shell=True,
            check=False,
        )
        print(f"stopped bridge pid {fields[0]}")
    time.sleep(1)
    subprocess.check_call(
        "docker exec openclaw-gateway-v2 sh -lc "
        "'nohup python3 /data/state/codex-bridge/package/server/codex_bridge_server.py "
        "--listen 127.0.0.1 --port 18991 "
        ">>/data/state/codex-bridge/server.out 2>&1 < /dev/null &'",
        shell=True,
    )
    time.sleep(1)


def bridge_health() -> dict[str, object]:
    try:
        raw = subprocess.check_output(
            "docker exec openclaw-gateway-v2 sh -lc 'curl -fsS http://127.0.0.1:18991/health'",
            shell=True,
            text=True,
            timeout=8,
        )
        return json.loads(raw)
    except Exception:
        with urllib.request.urlopen("http://127.0.0.1:18991/health", timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))


def main() -> None:
    here = Path(__file__).resolve().parent
    missing = [name for name in PATCH_ORDER if not (here / name).exists()]
    if missing:
        raise SystemExit(f"missing patch scripts next to deploy helper: {', '.join(missing)}")
    existing_targets = [target for target in TARGETS if target.exists()]
    if not existing_targets:
        raise SystemExit("no OpenWrt bridge target files found")

    for name in PATCH_ORDER:
        run_patch(here / name)
    py_compile(existing_targets)
    for target in existing_targets:
        verify_markers(target)
    clear_non_group_progress_bindings()
    restart_bridge()
    health = bridge_health()
    if not health.get("ok"):
        raise RuntimeError(f"bridge health check failed: {health}")
    print(json.dumps({"ok": True, "health": health}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
