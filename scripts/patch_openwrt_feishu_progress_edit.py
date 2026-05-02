#!/usr/bin/env python3
"""Patch OpenWrt bridge to edit one Feishu progress card for long tasks."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


PROGRESS_BLOCK = r'''def build_feishu_progress_card(task_id, text, *, done=False, error=False):
    content=str(text or '').strip() or ('已完成。' if done else '正在处理...')
    if len(content) > int(os.environ.get('CODEX_FEISHU_PROGRESS_CARD_LIMIT','3000')):
        content=content[-int(os.environ.get('CODEX_FEISHU_PROGRESS_CARD_LIMIT','3000')):]
    title='Codex 完成' if done and not error else 'Codex 失败' if error else 'Codex 处理中'
    template='green' if done and not error else 'red' if error else 'blue'
    return {
        'schema':'2.0',
        'config':{'wide_screen_mode':True},
        'header':{
            'template':template,
            'title':{'tag':'plain_text','content':title},
        },
        'body':{
            'direction':'vertical',
            'elements':[
                {'tag':'markdown','content':content},
                {'tag':'hr'},
                {'tag':'markdown','content':'任务：`'+str(task_id or '')+'`'},
            ],
        },
    }

def send_feishu_card_api(card,target,account='default'):
    token,cfg=feishu_tenant_token(account)
    receive_id_type='chat_id' if str(target or '').startswith('oc_') else 'open_id'
    url=feishu_api_base(cfg.get('domain')) + '/im/v1/messages?receive_id_type=' + receive_id_type
    body={'receive_id':target,'msg_type':'interactive','content':json.dumps(card,ensure_ascii=False)}
    req=urllib.request.Request(url,data=json.dumps(body,ensure_ascii=False).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+token},method='POST')
    with urllib.request.urlopen(req,timeout=20) as resp:
        payload=json.loads(resp.read().decode())
    ok=int(payload.get('code') or 0) == 0
    data=payload.get('data') or {}
    message_id=data.get('message_id') or data.get('messageId') or ''
    rec_payload={'ok':ok,'channel':'feishu','action':'send','messageId':message_id,'chatId':target,'fastApi':True,'msgType':'interactive','progressCard':True}
    return {'ts':now(),'rc':0 if ok else 1,'channel':'feishu','account':account,'target':target,'stdout':json.dumps({'payload':rec_payload},ensure_ascii=False),'stderr':'','message':'[progress-card]','card':card,'fast_api':True}

def update_feishu_message_api(message_id, card, account='default'):
    message_id=str(message_id or '').strip()
    if not message_id:
        return {'ts':now(),'rc':2,'error':'missing message_id'}
    token,cfg=feishu_tenant_token(account)
    url=feishu_api_base(cfg.get('domain')) + '/im/v1/messages/' + quote(message_id, safe='')
    body={'content':json.dumps(card,ensure_ascii=False)}
    req=urllib.request.Request(url,data=json.dumps(body,ensure_ascii=False).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+token},method='PATCH')
    with urllib.request.urlopen(req,timeout=20) as resp:
        payload=json.loads(resp.read().decode())
    ok=int(payload.get('code') or 0) == 0
    rec_payload={'ok':ok,'channel':'feishu','action':'update','messageId':message_id,'fastApi':True,'msgType':'interactive','progressCard':True}
    if not ok:
        rec_payload['error']=payload.get('msg') or payload
    return {'ts':now(),'rc':0 if ok else 1,'channel':'feishu','account':account,'target':message_id,'stdout':json.dumps({'payload':rec_payload},ensure_ascii=False),'stderr':'','message':'[progress-card-update]','card':card,'fast_api':True}

def feishu_progress_message_id(rec):
    try:
        payload=json.loads(str((rec or {}).get('stdout') or '{}'))
    except Exception:
        payload={}
    cur=payload
    for key in ('payload','result'):
        if isinstance(cur,dict) and isinstance(cur.get(key),dict):
            cur=cur.get(key)
    if isinstance(cur,dict):
        return str(cur.get('messageId') or cur.get('message_id') or '').strip()
    return ''

def feishu_progress_safe_final_text(text, done=False, error=False):
    fallback='任务失败。' if error else '已完成。' if done else '正在处理...'
    clean=' '.join(str(text or '').split()).strip() or fallback
    limit=max(120,min(900,int(os.environ.get('CODEX_FEISHU_PROGRESS_SAFE_FINAL_LIMIT','700'))))
    if len(clean) > limit:
        clean=clean[:limit].rstrip()+'...'
    return clean

'''


WATCH_FUNCTION = r'''def watch_fleet_task_completion(task_id, item, run_dir=None):
    timeout=float(os.environ.get('CODEX_FLEET_COMPLETION_PUSH_TIMEOUT','900'))
    interval=float(os.environ.get('CODEX_FLEET_COMPLETION_PUSH_INTERVAL','0.25'))
    interval=max(0.1,interval)
    progress_edit_interval=max(0.5,float(os.environ.get('CODEX_FEISHU_PROGRESS_EDIT_INTERVAL','1')))
    progress_min_chars=max(1,int(os.environ.get('CODEX_FEISHU_PROGRESS_MIN_CHARS','1')))
    deadline=time.time()+max(10,timeout); last=''
    feishu_group=run_dir_is_feishu_group(run_dir)
    try:
        run_meta=read_json(Path(run_dir)/'meta.json',{}) if run_dir else {}
        feishu_chat=feishu_group or is_feishu_channel(run_meta.get('channel')) or is_feishu_channel(run_meta.get('session_key'))
    except Exception:
        run_meta={}; feishu_chat=feishu_group
    feishu_target=feishu_target_from_meta(run_meta) if feishu_chat else ''
    feishu_account=feishu_account_from_meta(run_meta) if feishu_chat else 'default'
    def adopt_feishu_task_target(task):
        nonlocal feishu_chat,feishu_target,feishu_account
        if not isinstance(task,dict):
            return
        channel=task.get('chat_channel')
        chat_id=task.get('chat_id')
        if is_feishu_channel(channel) and is_feishu_group_chat_id(chat_id):
            feishu_chat=True
            _,owner=feishu_owner_chat_id(channel,chat_id,'')
            feishu_target=owner or normalize_feishu_chat_id(channel,chat_id,'')
            feishu_account=feishu_account or 'default'
    seen_event_id=0
    progress_buffer=[]
    progress_message_id=''
    last_progress_edit=0.0
    last_progress_text=''
    def task_send(message, kind='message', ev=None):
        if feishu_chat:
            key=f'fleet-task:{task_id}:{kind}:{hash_text(message)}'
            data={'task_id':task_id,'kind':kind,'event':ev}
            if feishu_target:
                return enqueue_outbound_message(key,message,channel='feishu',account=feishu_account or 'default',target=feishu_target,run_dir=run_dir,event=data)
            return enqueue_feishu_run_message(key,message,run_dir,data)
        return send_human(message,run_dir)
    def compact_progress_text():
        text=''.join(progress_buffer).strip()
        text=re.sub(r'\n{3,}','\n\n',text)
        limit=int(os.environ.get('CODEX_FEISHU_PROGRESS_CARD_LIMIT','3000'))
        return text[-limit:] if len(text) > limit else text
    def progress_card_update(force=False, done=False, error=False, final_text=''):
        nonlocal progress_message_id,last_progress_edit,last_progress_text
        if not feishu_chat or not feishu_target:
            return None
        text=str(final_text or '').strip() or compact_progress_text()
        if not text:
            return None
        if not done and not error:
            try:
                final_sent=globals().get('is_task_final_notification_sent')
                if callable(final_sent) and final_sent(task_id,feishu_target):
                    if run_dir:
                        append(Path(run_dir)/'feishu-progress-card.log',json.dumps({'ts':now(),'task_id':task_id,'message_id':progress_message_id,'action':'skip_progress_after_final_notify','text':text},ensure_ascii=False))
                    return None
            except Exception:
                pass
            try:
                cur_task=fleet_task_status(task_id) or {}
                cur_status=str(cur_task.get('status') or '').strip()
                if cur_status in ('completed','error','cancelled'):
                    if run_dir:
                        append(Path(run_dir)/'feishu-progress-card.log',json.dumps({'ts':now(),'task_id':task_id,'message_id':progress_message_id,'action':'skip_progress_after_terminal_status','status':cur_status,'text':text},ensure_ascii=False))
                    return None
            except Exception:
                pass
        now_ts=time.time()
        if not force and not done and not error:
            if len(text) < progress_min_chars and not progress_message_id:
                return None
            if progress_message_id and now_ts-last_progress_edit < progress_edit_interval:
                return None
            if text == last_progress_text:
                return None
        card=build_feishu_progress_card(task_id,text,done=done,error=error)
        def send_or_update(card_obj):
            nonlocal progress_message_id
            if progress_message_id:
                return update_feishu_message_api(progress_message_id,card_obj,feishu_account)
            rec_obj=send_feishu_card_api(card_obj,feishu_target,feishu_account)
            mid=feishu_progress_message_id(rec_obj)
            if mid:
                progress_message_id=mid
            return rec_obj
        try:
            rec=send_or_update(card)
            if (done or error) and int((rec or {}).get('rc',1)) != 0:
                safe_text=feishu_progress_safe_final_text(text,done=done,error=error)
                rec=send_or_update(build_feishu_progress_card(task_id,safe_text,done=done,error=error))
                text=safe_text
            last_progress_edit=now_ts
            last_progress_text=text
            if run_dir:
                append(Path(run_dir)/'feishu-progress-card.log',json.dumps({'ts':now(),'task_id':task_id,'message_id':progress_message_id,'done':done,'error':error,'rc':rec.get('rc'),'text':text,'send':rec},ensure_ascii=False))
            return rec
        except Exception as e:
            if done or error:
                safe_text=feishu_progress_safe_final_text(text,done=done,error=error)
                try:
                    rec=send_or_update(build_feishu_progress_card(task_id,safe_text,done=done,error=error))
                    last_progress_edit=now_ts
                    last_progress_text=safe_text
                    if run_dir:
                        append(Path(run_dir)/'feishu-progress-card.log',json.dumps({'ts':now(),'task_id':task_id,'message_id':progress_message_id,'done':done,'error':error,'rc':rec.get('rc'),'text':safe_text,'send':rec,'fallback_after_error':repr(e)},ensure_ascii=False))
                    return rec
                except Exception as e2:
                    if run_dir:
                        append(Path(run_dir)/'feishu-progress-card.log',json.dumps({'ts':now(),'task_id':task_id,'message_id':progress_message_id,'error':repr(e2),'first_error':repr(e),'text':safe_text,'done':done},ensure_ascii=False))
                    return None
            if run_dir:
                append(Path(run_dir)/'feishu-progress-card.log',json.dumps({'ts':now(),'task_id':task_id,'message_id':progress_message_id,'error':repr(e),'text':text},ensure_ascii=False))
            return None
    if feishu_chat and feishu_target and os.environ.get('CODEX_FEISHU_PROGRESS_BOOTSTRAP','1') != '0':
        progress_buffer.append(str(os.environ.get('CODEX_FEISHU_PROGRESS_BOOTSTRAP_TEXT','正在处理...')).strip() or '正在处理...')
        progress_card_update(force=True)
        progress_buffer.clear()
        last_progress_text=''
        last_progress_edit=0.0
    while time.time()<deadline:
        try:
            events=fleet_task_events(task_id,50)
            task=fleet_task_status(task_id) or {}
            adopt_feishu_task_target(task)
            if feishu_chat:
                newest=seen_event_id
                for ev in reversed(events):
                    eid=fleet_event_id(ev)
                    if eid <= seen_event_id:
                        continue
                    newest=max(newest,eid)
                    text=fleet_event_progress_text(ev)
                    if text:
                        progress_buffer.append(text if text.endswith('\n') else text+'\n')
                seen_event_id=newest
                progress_card_update()
            final_summary=''
            final_status=''
            final_event=None
            for ev in reversed(events):
                etype=ev.get('type')
                if etype in ('task/final','task/completed'):
                    final_summary=' '.join(str(ev.get('message') or '').split()).strip()
                    final_status='completed'
                    final_event=ev
                    break
                if etype == 'task/error':
                    final_summary=' '.join(str(ev.get('message') or '').split()).strip()
                    final_status='error'
                    final_event=ev
                    break
            if final_status == 'completed' and final_summary:
                if feishu_chat:
                    if progress_message_id:
                        if not progress_card_update(force=True,done=True,final_text=final_summary):
                            progress_card_update(force=True,done=True,final_text=feishu_progress_safe_final_text(final_summary,done=True))
                    else:
                        task_send(final_summary,'final',final_event)
                else:
                    task_send('公司 Codex 完成'+fleet_task_visibility_note(task_id)+'：\n'+final_summary,'final',final_event)
                return
            if final_status == 'error':
                if feishu_chat and progress_message_id:
                    if not progress_card_update(force=True,error=True,final_text=final_summary or '任务失败'):
                        progress_card_update(force=True,error=True,final_text=feishu_progress_safe_final_text(final_summary,done=False,error=True))
                else:
                    task_send(('任务失败：' if feishu_chat else '公司 Codex 任务失败：')+(final_summary or str(task_id)),'error',final_event)
                return
            status=str(task.get('status') or '').strip(); last=status or last
            if status in ('completed','error','cancelled'):
                summary=' '.join(str(task.get('last_summary') or final_summary or '').split()).strip()
                if feishu_chat:
                    if status=='completed':
                        if progress_message_id:
                            if not progress_card_update(force=True,done=True,final_text=summary or '已完成。'):
                                progress_card_update(force=True,done=True,final_text=feishu_progress_safe_final_text(summary,done=True))
                        else:
                            task_send(summary or '已完成。','completed',final_event)
                    elif status=='cancelled':
                        if progress_message_id:
                            progress_card_update(force=True,error=True,final_text='任务已取消：'+str(task_id))
                        else:
                            task_send('任务已取消：'+str(task_id),'cancelled',final_event)
                    else:
                        if progress_message_id:
                            progress_card_update(force=True,error=True,final_text=summary or '任务失败：'+str(task_id))
                        else:
                            task_send('任务失败：'+(summary or str(task_id)),'error',final_event)
                elif status=='completed': task_send('公司 Codex 完成'+fleet_task_visibility_note(task_id)+'：\n'+(summary or '已完成。'),'completed',final_event)
                elif status=='cancelled': task_send('公司 Codex 任务已取消：'+str(task_id),'cancelled',final_event)
                else: task_send('公司 Codex 任务失败：'+(summary or str(task_id)),'error',final_event)
                return
        except Exception as e:
            append(STATE/'server.log',f'{now()} fleet completion watcher failed task={task_id}: {e}')
        time.sleep(interval)
    if feishu_chat and progress_message_id:
        progress_card_update(force=True,final_text=f'任务仍在处理：{task_id}，最后状态 {last or "unknown"}。可说“现在状态”查看。')
    else:
        task_send(f'公司 Codex 任务仍未完成：{task_id}，最后状态 {last or "unknown"}。可说“现在状态”查看。','timeout')

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
    backup = path.with_name(path.name + f".bak-feishu-progress-edit-{stamp}")
    shutil.copy2(path, backup)

    if "def build_feishu_progress_card(" in text:
        start = text.find("def build_feishu_progress_card(")
        end = text.find("def watch_fleet_task_completion(", start)
        if end < 0:
            raise RuntimeError(f"watch_fleet_task_completion marker not found after progress block in {path}")
        text = text[:start] + PROGRESS_BLOCK + text[end:]
    else:
        text = text.replace("def watch_fleet_task_completion(task_id, item, run_dir=None):\n", PROGRESS_BLOCK + "def watch_fleet_task_completion(task_id, item, run_dir=None):\n")

    text = replace_between(text, "def watch_fleet_task_completion(task_id, item, run_dir=None):\n", "def start_fleet_completion_watcher", WATCH_FUNCTION)

    text = text.replace(
        "if etype in ('agent_message_delta','response.output_text.delta','assistant/delta'):",
        "if etype in ('agent_message_delta','response.output_text.delta','assistant/delta','vscode/assistant'):",
    )
    text = text.replace(
        "interval=max(1.0,float(os.environ.get('CODEX_FLEET_SESSION_MIRROR_INTERVAL','2.0')))",
        "interval=max(0.2,float(os.environ.get('CODEX_FLEET_SESSION_MIRROR_INTERVAL','0.5')))",
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
