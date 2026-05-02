#!/usr/bin/env python3
"""Patch OpenWrt bridge so company Codex routing only accepts Feishu groups."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


ROUTE_FEISHU_SESSION_ENTRY = r'''def route_feishu_session_entry(text, session_key='', run_dir=None, channel='', chat_id=''):
    if not is_feishu_channel(channel):
        return ''
    if not is_feishu_group_target(channel,chat_id,session_key):
        return ''
    selector,prompt=parse_session_entry_send(text)
    if selector and prompt:
        channel,owner=feishu_owner_chat_id(channel,chat_id,session_key)
        result=fleet_api('/api/session-chats/task',method='POST',body={'channel':channel,'owner_chat_id':owner,'selector':selector,'prompt':prompt})
        task=(result or {}).get('task') or {}
        mapping=(result or {}).get('mapping') or {}
        binding=(mapping or {}).get('binding') or {}
        task_id=task.get('task_id') or ''
        if task_id:
            start_fleet_completion_watcher(task_id,{'session_id':binding.get('session_id'),'project':binding.get('project_alias'),'source':'session-entry'},run_dir)
        return f'已发送到 Codex 会话 {selector}：{task_id or "queued"}'
    ch,cid=chat_identity(channel,chat_id,session_key)
    if ':thread:' in str(cid):
        routed=route_to_bound_chat(text,session_key,run_dir,ch,cid)
        if routed:
            return routed
    return ''

'''


BIND_CHAT_TO_PROJECT = r'''def bind_chat_to_project(text, session_key='', channel='', chat_id=''):
    alias=parse_chat_bind_request(text)
    if not alias:
        return ''
    if is_feishu_channel(channel) and not is_feishu_group_target(channel,chat_id,session_key):
        return ''
    channel,chat_id=chat_identity(channel,chat_id,session_key)
    body={'channel':channel,'chat_id':chat_id,'profile':session_key,'project_alias':alias}
    binding=fleet_api('/api/chat-bindings',method='POST',body=body)
    return f'已绑定当前聊天窗口到公司工程：{binding.get("project_alias") or alias}\n后续普通消息会直接发送到该工程；可用 /状态、/停止、/解绑。'

'''


ROUTE_TO_BOUND_CHAT = r'''def route_to_bound_chat(text, session_key='', run_dir=None, channel='', chat_id='', retry=False):
    if is_feishu_channel(channel) and not is_feishu_group_target(channel,chat_id,session_key):
        return ''
    channel,chat_id=chat_identity(channel,chat_id,session_key)
    status=fleet_chat_status(channel,chat_id)
    binding=status.get('binding') if isinstance(status,dict) else None
    if not binding:
        return ''
    if not str(text or '').strip():
        return ''
    task=fleet_api('/api/chat-bindings/task',method='POST',body={'channel':channel,'chat_id':chat_id,'prompt':str(text)})
    task_id=(task or {}).get('task_id') if isinstance(task,dict) else ''
    state=(task or {}).get('status') if isinstance(task,dict) else ''
    guidance=bool((task or {}).get('guidance')) if isinstance(task,dict) else False
    item={'number':'工程','session_id':task.get('session_id') or '', 'source':'project', 'project':binding.get('project_alias'), 'title':'飞书/聊天窗口绑定', 'guidance':guidance} if isinstance(task,dict) else {}
    if task_id: start_fleet_completion_watcher(task_id,item,run_dir)
    if is_feishu_group_target(channel,chat_id,session_key):
        return DIRECT_FLEET_NO_REPLY
    prefix='已补充到当前公司 Codex 任务：' if guidance else '已重试公司 Codex 工程：' if retry else '已发送到公司 Codex 工程：'
    lines=[prefix+str(binding.get('project_alias') or 'unknown')]
    if task_id:
        if guidance:
            lines.append(f'任务 {task_id} 已收到补充指令，正在尝试引导当前运行中的 VS Code/Codex。')
        else:
            lines.append(f'任务 {task_id} 已下发，状态 {state or "queued"}。完成后我会再发一条结果；若走历史 fallback，不会实时显示在 VS Code。')
    else: lines.append('任务已下发。')
    return '\n'.join(lines)

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
    backup = path.with_name(path.name + f".bak-feishu-group-routes-{stamp}")
    shutil.copy2(path, backup)

    text = replace_between(
        text,
        "def route_feishu_session_entry(text, session_key='', run_dir=None, channel='', chat_id=''):\n",
        "def parse_chat_bind_request",
        ROUTE_FEISHU_SESSION_ENTRY,
    )
    text = replace_between(
        text,
        "def bind_chat_to_project(text, session_key='', channel='', chat_id=''):\n",
        "def unbind_chat_project",
        BIND_CHAT_TO_PROJECT,
    )
    text = replace_between(
        text,
        "def route_to_bound_chat(text, session_key='', run_dir=None, channel='', chat_id='', retry=False):\n",
        "\ndef load_feishu_session_mirror_state",
        ROUTE_TO_BOUND_CHAT,
    )

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
