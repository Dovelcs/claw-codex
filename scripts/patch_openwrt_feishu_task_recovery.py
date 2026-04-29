#!/usr/bin/env python3
"""Patch OpenWrt bridge to recover Feishu task replies after watcher loss."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


TASK_FINAL_GUARD = r'''def task_final_notify_key(task_id, target):
    return str(task_id or '')+'|'+str(target or '')

def mark_task_final_notification(task_id, target, event_id=''):
    if not task_id or not target:
        return True
    with TASK_FINAL_NOTIFY_LOCK:
        state=read_json(TASK_FINAL_NOTIFY_STATE,{'version':1,'sent':{}})
        sent=state.setdefault('sent',{})
        key=task_final_notify_key(task_id,target)
        if key in sent:
            return False
        sent[key]={'task_id':str(task_id),'target':str(target),'event_id':str(event_id or ''),'sent_at':now()}
        if len(sent) > 500:
            for old in sorted(sent, key=lambda k: str(sent[k].get('sent_at') or ''))[:100]:
                sent.pop(old,None)
        write_json(TASK_FINAL_NOTIFY_STATE,state)
        return True

'''


def replace_once(text: str, old: str, new: str) -> str:
    if old not in text:
        raise RuntimeError(f"marker not found: {old[:120]}")
    return text.replace(old, new, 1)


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-feishu-task-recovery-{stamp}")
    shutil.copy2(path, backup)

    if "TASK_FINAL_NOTIFY_STATE" not in text:
        text = replace_once(
            text,
            "OUTBOUND_QUEUE_DB=STATE/'outbound-message-queue.sqlite3'; OUTBOUND_QUEUE_LOG=STATE/'outbound-message-queue.log'\n",
            "OUTBOUND_QUEUE_DB=STATE/'outbound-message-queue.sqlite3'; OUTBOUND_QUEUE_LOG=STATE/'outbound-message-queue.log'; TASK_FINAL_NOTIFY_STATE=STATE/'feishu-task-final-notify.json'\n",
        )
        text = replace_once(
            text,
            "RUNS_STATE={}; PROCS={}; CANCELLED=set(); LOCK=threading.Lock(); SEND_LOCK=threading.Lock(); OUTBOUND_QUEUE_LOCK=threading.Lock(); OUTBOUND_QUEUE_WAKE=queue.Queue(maxsize=1)\n",
            "RUNS_STATE={}; PROCS={}; CANCELLED=set(); LOCK=threading.Lock(); SEND_LOCK=threading.Lock(); OUTBOUND_QUEUE_LOCK=threading.Lock(); OUTBOUND_QUEUE_WAKE=queue.Queue(maxsize=1); TASK_FINAL_NOTIFY_LOCK=threading.Lock()\n",
        )

    if "def task_final_notify_key(" not in text:
        text = replace_once(text, "def watch_fleet_task_completion(task_id, item, run_dir=None):\n", TASK_FINAL_GUARD + "def watch_fleet_task_completion(task_id, item, run_dir=None):\n")

    text = text.replace(
        "    last_progress_text=''\n    def task_send(message, kind='message', ev=None):",
        "    last_progress_text=''\n    guidance_watch=bool((item or {}).get('guidance')) if isinstance(item,dict) else False\n    def task_send(message, kind='message', ev=None):",
    )
    text = text.replace(
        "    if feishu_chat and feishu_target and os.environ.get('CODEX_FEISHU_PROGRESS_BOOTSTRAP','1') != '0':",
        "    if feishu_chat and feishu_target and not guidance_watch and os.environ.get('CODEX_FEISHU_PROGRESS_BOOTSTRAP','1') != '0':",
    )
    text = text.replace(
        "            if final_status == 'completed' and final_summary:\n                if feishu_chat:",
        "            if final_status == 'completed' and final_summary:\n                if feishu_chat and not mark_task_final_notification(task_id,feishu_target,fleet_event_id(final_event) if final_event else ''):\n                    return\n                if feishu_chat:",
    )
    text = text.replace(
        "            if final_status == 'error':\n                if feishu_chat and progress_message_id:",
        "            if final_status == 'error':\n                if feishu_chat and not mark_task_final_notification(task_id,feishu_target,fleet_event_id(final_event) if final_event else ''):\n                    return\n                if feishu_chat and progress_message_id:",
    )
    text = text.replace(
        "            if status in ('completed','error','cancelled'):\n                summary=' '.join(str(task.get('last_summary') or final_summary or '').split()).strip()\n                if feishu_chat:",
        "            if status in ('completed','error','cancelled'):\n                summary=' '.join(str(task.get('last_summary') or final_summary or '').split()).strip()\n                if feishu_chat and not mark_task_final_notification(task_id,feishu_target,fleet_event_id(final_event) if final_event else ''):\n                    return\n                if feishu_chat:",
    )

    text = text.replace(
        "    item={'number':'工程','session_id':task.get('session_id') or '', 'source':'project', 'project':binding.get('project_alias'), 'title':'飞书/聊天窗口绑定'} if isinstance(task,dict) else {}\n    if task_id and not guidance: start_fleet_completion_watcher(task_id,item,run_dir)",
        "    item={'number':'工程','session_id':task.get('session_id') or '', 'source':'project', 'project':binding.get('project_alias'), 'title':'飞书/聊天窗口绑定', 'guidance':guidance} if isinstance(task,dict) else {}\n    if task_id: start_fleet_completion_watcher(task_id,item,run_dir)",
    )

    task_fallback = r'''                    task_id=str(ev.get('task_id') or '').strip()
                    if task_id:
                        etype=str(ev.get('type') or '')
                        if etype not in ('task/final','task/completed'):
                            continue
                        task=fleet_task_status(task_id) or {}
                        chat_id=str(task.get('chat_id') or '').strip()
                        if not chat_id or not is_feishu_channel(task.get('chat_channel')):
                            continue
                        text=str(ev.get('message') or '').strip()
                        if not text:
                            continue
                        target=normalize_feishu_chat_id('feishu',chat_id,'')
                        if target and mark_task_final_notification(task_id,target,eid):
                            send_feishu_session_mirror(chat_id,text,ev)
                        continue
'''
    text = text.replace(
        "                    if ev.get('task_id'):\n                        continue\n",
        task_fallback,
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
