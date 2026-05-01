#!/usr/bin/env python3
"""Patch OpenWrt bridge to edit Feishu progress cards for VS Code session mirrors."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/data/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


MIRROR_BLOCK = r'''def send_feishu_session_mirror(chat_id, message, event=None):
    target=normalize_feishu_chat_id('feishu',chat_id,'')
    event_id=(event or {}).get('event_id') if isinstance(event,dict) else None
    session_id=(event or {}).get('session_id') if isinstance(event,dict) else None
    etype=str((event or {}).get('type') or '') if isinstance(event,dict) else ''
    if etype == 'vscode/final':
        return {'ts':now(),'rc':0,'skipped':True,'reason':'vscode final handled by progress card','event_id':event_id,'session_id':session_id}
    if not target:
        return {'ts':now(),'rc':2,'error':'missing feishu chat target','message':str(message)}
    key=f'fleet-session:{event_id}:{target}' if event_id else f'fleet-session:{session_id}:{target}:{hash_text(message)}'
    rec=enqueue_outbound_message(key,message,channel='feishu',account='default',target=target,event=event)
    rec['event_id']=event_id
    rec['session_id']=session_id
    append(STATE/'feishu-session-mirror.log',json.dumps(rec,ensure_ascii=False))
    return rec

def feishu_session_progress_key(chat_id, session_id):
    return normalize_feishu_chat_id('feishu',chat_id,'')+'|'+str(session_id or '')

def feishu_session_final_key(chat_id, session_id, event=None, message=''):
    target=normalize_feishu_chat_id('feishu',chat_id,'')
    event_id=(event or {}).get('event_id') if isinstance(event,dict) else None
    if not event_id and isinstance(event,dict):
        try:
            event_id=fleet_event_id(event)
        except Exception:
            event_id=None
    suffix=str(event_id or '').strip() or hash_text(message)
    return target+'|'+str(session_id or '')+'|'+suffix

def mark_feishu_session_final(chat_id, session_id, event=None, message=''):
    target=normalize_feishu_chat_id('feishu',chat_id,'')
    if not target or not session_id:
        return True
    state=load_feishu_session_mirror_state()
    finals=state.setdefault('final_messages',{})
    key=feishu_session_final_key(chat_id,session_id,event,message)
    if key in finals:
        return False
    finals[key]={
        'ts':now(),
        'target':target,
        'session_id':session_id,
        'event_id':str((event or {}).get('event_id') or '').strip() if isinstance(event,dict) else '',
    }
    if len(finals) > 500:
        for old_key in sorted(finals, key=lambda k: str((finals.get(k) or {}).get('ts') or ''))[:len(finals)-500]:
            finals.pop(old_key,None)
    save_feishu_session_mirror_state(state)
    return True

def clear_feishu_session_progress_mirror(chat_id, session_id, event=None):
    target=normalize_feishu_chat_id('feishu',chat_id,'')
    if not target:
        return ''
    state=load_feishu_session_mirror_state()
    progress=state.setdefault('progress_messages',{})
    key=feishu_session_progress_key(chat_id,session_id)
    old=progress.pop(key,None)
    if old:
        save_feishu_session_mirror_state(state)
        append(STATE/'feishu-session-progress-mirror.log',json.dumps({
            'ts':now(),
            'action':'clear',
            'target':target,
            'session_id':session_id,
            'event_id':(event or {}).get('event_id') if isinstance(event,dict) else None,
            'progress_message_id':old,
        },ensure_ascii=False))
    return old or ''

def send_feishu_session_progress_mirror(chat_id, session_id, message, event=None, done=False, error=False):
    target=normalize_feishu_chat_id('feishu',chat_id,'')
    if not target:
        return {'ts':now(),'rc':2,'error':'missing feishu chat target','message':str(message)}
    state=load_feishu_session_mirror_state()
    progress=state.setdefault('progress_messages',{})
    key=feishu_session_progress_key(chat_id,session_id)
    message_id=str(progress.get(key) or '').strip()
    card=build_feishu_progress_card(session_id,message,done=done,error=error)
    try:
        if message_id:
            rec=update_feishu_message_api(message_id,card,'default')
            if int((rec or {}).get('rc',1)) != 0 and not done:
                rec=send_feishu_card_api(card,target,'default')
                message_id=feishu_progress_message_id(rec)
                if message_id:
                    progress[key]=message_id
        else:
            rec=send_feishu_card_api(card,target,'default')
            message_id=feishu_progress_message_id(rec)
            if message_id:
                progress[key]=message_id
        if done or error:
            progress.pop(key,None)
        save_feishu_session_mirror_state(state)
    except Exception as e:
        rec={'ts':now(),'rc':1,'error':repr(e),'target':target,'message':str(message),'message_id':message_id}
    rec['session_id']=session_id
    rec['event_id']=(event or {}).get('event_id') if isinstance(event,dict) else None
    rec['progress_message_id']=message_id
    rec['done']=done
    append(STATE/'feishu-session-progress-mirror.log',json.dumps(rec,ensure_ascii=False))
    return rec

def feishu_task_progress_message(task_id):
    task_id=str(task_id or '').strip()
    if not task_id:
        return '', 'group'
    try:
        paths=sorted((STATE/'runs').glob('*/feishu-progress-card.log'), key=lambda p: p.stat().st_mtime, reverse=True)
    except Exception:
        paths=[]
    for path in paths[:100]:
        try:
            lines=path.read_text(encoding='utf-8',errors='replace').splitlines()
        except Exception:
            continue
        for line in reversed(lines[-200:]):
            try:
                rec=json.loads(line)
            except Exception:
                continue
            if str(rec.get('task_id') or '').strip() != task_id:
                continue
            message_id=str(rec.get('message_id') or '').strip()
            if not message_id:
                continue
            send=rec.get('send') if isinstance(rec.get('send'),dict) else {}
            account=str(send.get('account') or rec.get('account') or 'group').strip() or 'group'
            return message_id, account
    return '', 'group'

def update_feishu_task_progress_final(task_id, chat_id, message, event=None, done=True, error=False):
    message_id,account=feishu_task_progress_message(task_id)
    if not message_id:
        return None
    card=build_feishu_progress_card(task_id,message,done=done,error=error)
    try:
        rec=update_feishu_message_api(message_id,card,account)
    except Exception as e:
        rec={'ts':now(),'rc':1,'error':repr(e),'task_id':task_id,'message_id':message_id}
    rec['task_id']=task_id
    rec['chat_id']=chat_id
    rec['event_id']=(event or {}).get('event_id') if isinstance(event,dict) else None
    rec['progress_message_id']=message_id
    rec['done']=done
    rec['error_done']=error
    append(STATE/'feishu-task-progress-fallback.log',json.dumps(rec,ensure_ascii=False))
    return rec

def feishu_session_mirror_text(ev):
    etype=str((ev or {}).get('type') or '')
    text=' '.join(str((ev or {}).get('message') or '').split()).strip()
    if not text:
        return ''
    if etype == 'vscode/user':
        return 'VS Code：'+text
    if etype in ('vscode/assistant','vscode/final'):
        return text
    return ''

def is_feishu_group_chat_id(chat_id):
    return str(chat_id or '').strip().startswith('oc_')

'''


WATCH_BLOCK = r'''def watch_feishu_session_events():
    interval=max(0.2,float(os.environ.get('CODEX_FLEET_SESSION_MIRROR_INTERVAL','0.5')))
    tail=max(20,min(300,int(os.environ.get('CODEX_FLEET_SESSION_MIRROR_TAIL','100'))))
    binding_ttl=max(5.0,float(os.environ.get('CODEX_FLEET_SESSION_MIRROR_BINDING_TTL','20')))
    state=load_feishu_session_mirror_state()
    try:
        seen=int(state.get('seen_event_id') or 0)
    except Exception:
        seen=0
    session_to_chats={}
    bindings_expires_at=0.0
    while True:
        try:
            now_ts=time.time()
            if now_ts >= bindings_expires_at:
                session_to_chats=feishu_session_mirror_bindings()
                bindings_expires_at=now_ts+binding_ttl
            if session_to_chats:
                payload=fleet_api('/api/events?tail='+str(tail))
                events=payload.get('events') if isinstance(payload,dict) else []
                newest=seen
                for ev in events if isinstance(events,list) else []:
                    eid=fleet_event_id(ev)
                    if eid > newest:
                        newest=eid
                    if eid <= seen:
                        continue
                    task_id=str(ev.get('task_id') or '').strip()
                    if task_id:
                        etype=str(ev.get('type') or '')
                        if etype not in ('task/final','task/completed'):
                            continue
                        task=fleet_task_status(task_id) or {}
                        chat_id=str(task.get('chat_id') or '').strip()
                        if not chat_id or not is_feishu_channel(task.get('chat_channel')):
                            continue
                        if not is_feishu_group_chat_id(chat_id):
                            continue
                        text=str(ev.get('message') or '').strip()
                        if not text:
                            continue
                        target=normalize_feishu_chat_id('feishu',chat_id,'')
                        if target and mark_task_final_notification(task_id,target,eid):
                            if not update_feishu_task_progress_final(task_id,chat_id,text,ev,done=True):
                                send_feishu_session_mirror(chat_id,text,ev)
                        continue
                    sid=str(ev.get('session_id') or '').strip()
                    if sid not in session_to_chats:
                        continue
                    text=feishu_session_mirror_text(ev)
                    if not text:
                        continue
                    etype=str(ev.get('type') or '')
                    for chat_id in session_to_chats.get(sid) or []:
                        if not is_feishu_group_chat_id(chat_id):
                            continue
                        if etype == 'vscode/assistant':
                            send_feishu_session_progress_mirror(chat_id,sid,text,ev,done=False)
                        elif etype == 'vscode/final':
                            if mark_feishu_session_final(chat_id,sid,ev,text):
                                send_feishu_session_progress_mirror(chat_id,sid,text,ev,done=True)
                        elif etype == 'vscode/user':
                            clear_feishu_session_progress_mirror(chat_id,sid,ev)
                            send_feishu_session_mirror(chat_id,text,ev)
                        else:
                            send_feishu_session_mirror(chat_id,text,ev)
                if newest > seen:
                    seen=newest
                    cur=load_feishu_session_mirror_state()
                    cur['seen_event_id']=seen
                    save_feishu_session_mirror_state(cur)
        except Exception as e:
            append(STATE/'server.log',f'{now()} feishu session mirror watcher failed: {e}')
        time.sleep(interval)

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
    backup = path.with_name(path.name + f".bak-feishu-session-progress-{stamp}")
    shutil.copy2(path, backup)

    text = replace_between(text, "def send_feishu_session_mirror(chat_id, message, event=None):\n", "def feishu_session_mirror_bindings", MIRROR_BLOCK)
    text = replace_between(text, "def watch_feishu_session_events():\n", "def start_feishu_session_mirror_watcher", WATCH_BLOCK)

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
