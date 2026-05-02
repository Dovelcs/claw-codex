#!/usr/bin/env python3
"""Apply the complete OpenWrt codex bridge patch set in a fixed order.

Run this script on OpenWrt from a directory that also contains the
patch_openwrt_*.py scripts from this repository.
"""

from __future__ import annotations

import json
import os
import runpy
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


STATE = Path("/opt/weixin-bot/data/openclaw/state/codex-bridge")
CONTAINER_STATE = Path("/data/state/codex-bridge")
RUNTIME_TARGET = CONTAINER_STATE / "package/server/codex_bridge_server.py"
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
    "patch_openwrt_direct_fleet_precontext.py",
    "patch_openwrt_feishu_fleet_passthrough.py",
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
HELPER_SCRIPTS = [
    "feishu_provision_session_groups.py",
    "feishu_auto_session_groups.sh",
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


def helper_script_dirs() -> list[Path]:
    dirs = []
    if STATE.exists():
        dirs.append(STATE / "scripts")
    if CONTAINER_STATE.exists():
        dirs.append(CONTAINER_STATE / "scripts")
    if not dirs:
        raise SystemExit("no codex bridge state directory found for helper scripts")
    return dirs


def sync_helper_scripts(here: Path) -> list[Path]:
    synced_paths: list[Path] = []
    for name in HELPER_SCRIPTS:
        source = here / name
        if not source.exists():
            raise SystemExit(f"missing helper script next to deploy helper: {name}")
        for scripts_dir in helper_script_dirs():
            scripts_dir.mkdir(parents=True, exist_ok=True)
            target = scripts_dir / name
            shutil.copy2(source, target)
            target.chmod(0o755)
            synced_paths.append(target)
            print(f"synced helper script {target}")
    return synced_paths


def sync_runtime_bridge(source: Path) -> Path | None:
    if not source.exists():
        return None
    if not RUNTIME_TARGET.parent.exists():
        subprocess.check_call(
            ["docker", "cp", str(source), f"openclaw-gateway-v2:{RUNTIME_TARGET}"]
        )
        print(f"synced runtime bridge openclaw-gateway-v2:{RUNTIME_TARGET}")
        return None
    if source.resolve() == RUNTIME_TARGET.resolve():
        return RUNTIME_TARGET
    backup = RUNTIME_TARGET.with_name(RUNTIME_TARGET.name + f".bak-runtime-sync-{time.strftime('%Y%m%d%H%M%S')}")
    if RUNTIME_TARGET.exists():
        shutil.copy2(RUNTIME_TARGET, backup)
        print(f"backup runtime bridge {backup}")
    shutil.copy2(source, RUNTIME_TARGET)
    print(f"synced runtime bridge {RUNTIME_TARGET}")
    return RUNTIME_TARGET


def start_auto_session_groups() -> None:
    subprocess.check_call(
        "docker exec openclaw-gateway-v2 sh -lc "
        "'script=/data/state/codex-bridge/scripts/feishu_auto_session_groups.sh; "
        "running=0; self=$$; "
        "for p in /proc/[0-9]*; do "
        "pid=${p#/proc/}; [ \"$pid\" = \"$self\" ] && continue; "
        "cmd=$(tr \"\\000\" \" \" < \"$p/cmdline\" 2>/dev/null || true); "
        "case \"$cmd\" in *\"$script\"*) running=1;; esac; "
        "done; "
        "if [ -x \"$script\" ] && [ \"$running\" = 0 ]; then "
        "nohup \"$script\" >>/data/state/codex-bridge/feishu-auto-session-groups.out 2>&1 < /dev/null & "
        "echo $! >/data/state/codex-bridge/feishu-auto-session-groups.pid; "
        "echo started feishu auto session groups; "
        "fi'",
        shell=True,
    )


def restart_openclaw_container() -> None:
    subprocess.check_call("docker restart openclaw-gateway-v2 >/dev/null", shell=True)
    time.sleep(5)


def restart_bridge() -> None:
    stopped: list[str] = []
    try:
        out = subprocess.check_output("ps w || ps", shell=True, text=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"cannot list host bridge processes: {exc}") from exc
    for line in out.splitlines():
        if "codex_bridge_server.py" not in line or "grep" in line:
            continue
        fields = line.split()
        if not fields:
            continue
        subprocess.run(["kill", "-TERM", fields[0]], check=False)
        stopped.append(fields[0])
        print(f"stopped host bridge pid {fields[0]}")
    try:
        out = subprocess.check_output("docker exec openclaw-gateway-v2 sh -lc 'ps w || ps'", shell=True, text=True)
    except subprocess.CalledProcessError:
        out = ""
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
        stopped.append("container:" + fields[0])
        print(f"stopped container bridge pid {fields[0]}")
    time.sleep(1)
    for pid in stopped:
        if pid.startswith("container:"):
            continue
        subprocess.run(["kill", "-KILL", pid], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        subprocess.check_call(
            "docker exec openclaw-gateway-v2 sh -lc "
            "'nohup python3 /data/state/codex-bridge/package/server/codex_bridge_server.py "
            "--listen 127.0.0.1 --port 18991 "
            ">>/data/state/codex-bridge/server.out 2>&1 < /dev/null &'",
            shell=True,
        )
    except subprocess.CalledProcessError:
        if not RUNTIME_TARGET.parent.exists():
            raise
        subprocess.check_call(
            "nohup python3 /data/state/codex-bridge/package/server/codex_bridge_server.py "
            "--listen 127.0.0.1 --port 18991 "
            ">>/data/state/codex-bridge/server.out 2>&1 < /dev/null &",
            shell=True,
        )
    time.sleep(1)


def py_compile_runtime_bridge(runtime_target: Path | None) -> None:
    if runtime_target:
        py_compile([runtime_target])
        return
    subprocess.check_call(
        "docker exec openclaw-gateway-v2 sh -lc "
        "'python3 -m py_compile /data/state/codex-bridge/package/server/codex_bridge_server.py'",
        shell=True,
    )


def verify_runtime_markers(runtime_target: Path | None) -> None:
    if runtime_target:
        verify_markers(runtime_target)
        return
    raw = subprocess.check_output(
        "docker exec openclaw-gateway-v2 sh -lc "
        "'python3 - <<\"PY\"\n"
        "from pathlib import Path\n"
        "text=Path(\"/data/state/codex-bridge/package/server/codex_bridge_server.py\").read_text(encoding=\"utf-8\")\n"
        "missing=[m for m in [\"def enqueue_outbound_message(\",\"def build_feishu_progress_card(\",\"def mark_task_final_notification(\",\"def clear_feishu_session_progress_mirror(\",\"def is_feishu_group_chat_id(\",\"if is_feishu_channel(channel) and not is_feishu_group_target(channel,chat_id,session_key):\",\"def is_company_fleet_channel(\"] if m not in text]\n"
        "if missing: raise SystemExit(\"missing runtime markers: \"+repr(missing))\n"
        "PY'",
        shell=True,
        text=True,
    )
    if raw.strip():
        print(raw.strip())


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
    runtime_target = sync_runtime_bridge(existing_targets[0])
    synced_helpers = sync_helper_scripts(here)
    py_compile(existing_targets)
    py_compile_runtime_bridge(runtime_target)
    py_compile([path for path in synced_helpers if path.suffix == ".py"])
    for target in existing_targets:
        verify_markers(target)
    verify_runtime_markers(runtime_target)
    clear_non_group_progress_bindings()
    restart_bridge()
    restart_openclaw_container()
    start_auto_session_groups()
    health = bridge_health()
    if not health.get("ok"):
        raise RuntimeError(f"bridge health check failed: {health}")
    print(json.dumps({"ok": True, "health": health}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
