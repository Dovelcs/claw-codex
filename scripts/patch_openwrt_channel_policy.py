#!/usr/bin/env python3
"""Patch OpenWrt bridge channel policy: Feishu controls company fleet, WeChat stays local."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


POLICY_BLOCK = r'''def is_company_fleet_channel(channel):
    return is_feishu_channel(channel)

def try_direct_fleet_answer(text, session_key='', run_dir=None, channel='', chat_id=''):
    if not is_company_fleet_channel(channel):
        return ''
    text=clean_chat_text(text,channel)
    if is_session_entry_sync_request(text):
        return publish_feishu_session_entries(text,session_key,run_dir,channel,chat_id)
    if is_session_entry_list_request(text):
        return format_feishu_session_entries(session_key,channel,chat_id)
    routed_entry=route_feishu_session_entry(text,session_key,run_dir,channel,chat_id)
    if routed_entry:
        return routed_entry
    bound=bind_chat_to_project(text,session_key,channel,chat_id)
    if bound:
        return bound
    if is_chat_unbind_request(text):
        return unbind_chat_project(session_key,channel,chat_id)
    if is_chat_status_request(text):
        return format_chat_binding_status(session_key,channel,chat_id)
    if is_chat_stop_request(text):
        return stop_chat_task(session_key,channel,chat_id)
    if is_chat_retry_request(text):
        return retry_chat_task(session_key,channel,chat_id,run_dir)
    if is_fleet_clear_request(text):
        return clear_fleet_target(session_key)
    if is_fleet_target_query(text):
        return format_current_fleet_target(session_key)
    if is_fleet_status_query(text):
        return format_fleet_status_answer(session_key)
    selected=use_numbered_fleet_session(text,session_key)
    if selected:
        return selected
    if is_fleet_sessions_query(text):
        limit=50 if any(x in str(text or '') for x in ('更多','全部','所有')) else None
        return format_fleet_sessions_answer(limit=limit,session_key=session_key)
    routed=route_to_bound_chat(text,session_key,run_dir,channel,chat_id)
    if routed:
        return routed
    routed=route_to_active_fleet_session(text,session_key,run_dir)
    if routed:
        return routed
    if should_route_to_active_fleet(text):
        return '当前飞书窗口未绑定公司工程。请先发送 /绑定 codex-server 或 /绑定 rk3576-ect。'
    return ''

'''


def replace_between(text: str, start: str, end: str, replacement: str) -> str:
    start_index = text.find(start)
    if start_index < 0:
        raise RuntimeError(f"start marker not found: {start}")
    end_index = text.find(end, start_index)
    if end_index < 0:
        raise RuntimeError(f"end marker not found: {end}")
    return text[:start_index] + replacement + text[end_index:]


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-channel-policy-{stamp}")
    shutil.copy2(path, backup)

    if "def is_company_fleet_channel(" in text:
        text = replace_between(text, "def is_company_fleet_channel(channel):\n", "def preserve_cancel_fields", POLICY_BLOCK)
    else:
        text = replace_between(text, "def try_direct_fleet_answer(text, session_key='', run_dir=None, channel='', chat_id=''):\n", "def preserve_cancel_fields", POLICY_BLOCK)

    if text == original:
        print(f"unchanged {path}")
        backup.unlink(missing_ok=True)
        return
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")
    print(f"backup {backup}")


def main() -> None:
    for target in TARGETS:
        if target.exists():
            patch_file(target)


if __name__ == "__main__":
    main()
