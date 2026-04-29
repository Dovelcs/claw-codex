#!/usr/bin/env python3
"""Patch the deployed OpenWrt codex bridge to use a queued Feishu send path."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


QUEUE_BLOCK = r'''
def hash_text(value):
    return hashlib.sha256(str(value or '').encode('utf-8')).hexdigest()[:24]

def outbound_queue_conn():
    OUTBOUND_QUEUE_DB.parent.mkdir(parents=True,exist_ok=True)
    conn=sqlite3.connect(str(OUTBOUND_QUEUE_DB),timeout=10,isolation_level=None)
    conn.row_factory=sqlite3.Row
    conn.execute('pragma journal_mode=wal')
    conn.execute('pragma busy_timeout=5000')
    conn.execute("""create table if not exists outbound_message_queue (
      id integer primary key autoincrement,
      event_key text not null unique,
      channel text not null,
      account text,
      target text not null,
      message text not null,
      status text not null default 'pending',
      attempts integer not null default 0,
      next_attempt_at real not null default 0,
      run_dir text,
      event_json text,
      send_json text,
      created_at text not null,
      updated_at text not null,
      sent_at text
    )""")
    return conn

def init_outbound_queue():
    conn=outbound_queue_conn(); conn.close()

def wake_outbound_dispatcher():
    try:
        OUTBOUND_QUEUE_WAKE.put_nowait(1)
    except queue.Full:
        pass

def outbound_queue_stats():
    try:
        conn=outbound_queue_conn()
        rows=conn.execute('select status,count(*) as n from outbound_message_queue group by status').fetchall()
        conn.close()
        return {row['status']:int(row['n']) for row in rows}
    except Exception as e:
        return {'error':repr(e)}

def enqueue_outbound_message(event_key, message, *, channel='feishu', account='default', target='', run_dir=None, event=None):
    message=str(message or '').strip()
    target=str(target or '').strip()
    if not message:
        return {'queued':False,'reason':'empty message'}
    if not target:
        return {'queued':False,'reason':'missing target','message':message}
    event_key=str(event_key or '').strip() or f'{channel}:{target}:{hash_text(message)}'
    ts=now(); run_dir_text=str(run_dir) if run_dir else ''
    payload=json.dumps(event or {},ensure_ascii=False)
    inserted=False
    with OUTBOUND_QUEUE_LOCK:
        conn=outbound_queue_conn()
        try:
            conn.execute('begin immediate')
            cur=conn.execute("""insert or ignore into outbound_message_queue
              (event_key,channel,account,target,message,status,attempts,next_attempt_at,run_dir,event_json,created_at,updated_at)
              values(?,?,?,?,?,'pending',0,0,?,?,?,?)""",
              (event_key,channel,account,target,message,run_dir_text,payload,ts,ts))
            inserted=cur.rowcount > 0
            conn.commit()
        except Exception:
            conn.rollback(); raise
        finally:
            conn.close()
    rec={'ts':ts,'queued':True,'inserted':inserted,'event_key':event_key,'channel':channel,'account':account,'target':target,'message':message}
    append(OUTBOUND_QUEUE_LOG,json.dumps(rec,ensure_ascii=False))
    if run_dir:
        append(Path(run_dir)/'outbound-queue.log',json.dumps(rec,ensure_ascii=False))
    if inserted:
        wake_outbound_dispatcher()
    return rec

def enqueue_feishu_run_message(event_key, message, run_dir=None, event=None):
    meta=read_json(Path(run_dir)/'meta.json',{}) if run_dir else {}
    target=feishu_target_from_meta(meta)
    account=feishu_account_from_meta(meta)
    rec=enqueue_outbound_message(event_key,message,channel='feishu',account=account,target=target,run_dir=run_dir,event=event)
    if not rec.get('queued'):
        append(Path(run_dir or STATE)/'outbound-queue.log',json.dumps(rec,ensure_ascii=False))
    return rec

def claim_outbound_message():
    with OUTBOUND_QUEUE_LOCK:
        conn=outbound_queue_conn()
        try:
            conn.execute('begin immediate')
            row=conn.execute("""
              select * from outbound_message_queue
              where status in ('pending','retry') and next_attempt_at <= ?
              order by id asc limit 1
            """,(time.time(),)).fetchone()
            if not row:
                conn.commit(); return None
            conn.execute("update outbound_message_queue set status='sending',attempts=attempts+1,updated_at=? where id=?",(now(),row['id']))
            conn.commit()
            return dict(row)
        except Exception:
            conn.rollback(); raise
        finally:
            conn.close()

def complete_outbound_message(row, rec, error=None):
    status='sent' if not error and int((rec or {}).get('rc',1)) == 0 else 'retry'
    attempts=int((row or {}).get('attempts') or 0) + 1
    next_attempt=0 if status=='sent' else time.time()+min(300,2**min(attempts,8))
    if status != 'sent' and attempts >= int(os.environ.get('CODEX_OUTBOUND_QUEUE_MAX_ATTEMPTS','8')):
        status='failed'
    payload=rec if rec is not None else {'error':repr(error)}
    ts=now()
    with OUTBOUND_QUEUE_LOCK:
        conn=outbound_queue_conn()
        try:
            conn.execute("""
              update outbound_message_queue
              set status=?,send_json=?,next_attempt_at=?,updated_at=?,sent_at=case when ?='sent' then ? else sent_at end
              where id=?
            """,(status,json.dumps(payload,ensure_ascii=False),next_attempt,ts,status,ts,row['id']))
            conn.commit()
        finally:
            conn.close()
    out={'ts':ts,'event_key':row.get('event_key'),'status':status,'target':row.get('target'),'message':row.get('message'),'send':payload}
    append(OUTBOUND_QUEUE_LOG,json.dumps(out,ensure_ascii=False))
    if row.get('run_dir'):
        run_dir=Path(row.get('run_dir'))
        append(run_dir/'channel-send.log',json.dumps(payload,ensure_ascii=False))
        append(run_dir/'wechat-send.log',json.dumps(payload,ensure_ascii=False))
        append(run_dir/'outbound-queue.log',json.dumps(out,ensure_ascii=False))

def send_outbound_row(row):
    channel=str(row.get('channel') or '').lower()
    if channel == 'feishu' or channel.endswith('feishu'):
        return send_feishu_api(row.get('message') or '',row.get('target') or '',row.get('account') or 'default')
    return send_weixin(row.get('message') or '',row.get('run_dir') or None)

def outbound_dispatcher_loop():
    init_outbound_queue()
    while True:
        row=None
        try:
            row=claim_outbound_message()
            if not row:
                try:
                    OUTBOUND_QUEUE_WAKE.get(timeout=max(0.2,float(os.environ.get('CODEX_OUTBOUND_QUEUE_IDLE_INTERVAL','0.5'))))
                except queue.Empty:
                    pass
                continue
            rec=send_outbound_row(row)
            complete_outbound_message(row,rec)
        except Exception as e:
            append(STATE/'server.log',f'{now()} outbound dispatcher failed: {e}')
            if row:
                try:
                    complete_outbound_message(row,None,e)
                except Exception as inner:
                    append(STATE/'server.log',f'{now()} outbound complete failed: {inner}')
            time.sleep(1)

def start_outbound_dispatcher():
    disabled=str(os.environ.get('CODEX_OUTBOUND_QUEUE','1')).strip().lower() in ('0','false','off','no')
    if disabled:
        return
    init_outbound_queue()
    threading.Thread(target=outbound_dispatcher_loop,daemon=True).start()

'''


WATCH_FUNCTION = r'''def watch_fleet_task_completion(task_id, item, run_dir=None):
    timeout=float(os.environ.get('CODEX_FLEET_COMPLETION_PUSH_TIMEOUT','900'))
    interval=float(os.environ.get('CODEX_FLEET_COMPLETION_PUSH_INTERVAL','0.5'))
    interval=max(0.2,interval)
    deadline=time.time()+max(10,timeout); last=''
    feishu_group=run_dir_is_feishu_group(run_dir)
    try:
        run_meta=read_json(Path(run_dir)/'meta.json',{}) if run_dir else {}
        feishu_chat=feishu_group or is_feishu_channel(run_meta.get('channel')) or is_feishu_channel(run_meta.get('session_key'))
    except Exception:
        feishu_chat=feishu_group
    seen_event_id=0
    progress_pending=[]
    def task_send(message, kind='message', ev=None):
        if feishu_chat:
            key=f'fleet-task:{task_id}:{kind}:{hash_text(message)}'
            data={'task_id':task_id,'kind':kind,'event':ev}
            return enqueue_feishu_run_message(key,message,run_dir,data)
        return send_human(message,run_dir)
    while time.time()<deadline:
        try:
            events=fleet_task_events(task_id,50)
            if feishu_group:
                newest=seen_event_id
                for ev in reversed(events):
                    eid=fleet_event_id(ev)
                    if eid <= seen_event_id:
                        continue
                    newest=max(newest,eid)
                    text=fleet_event_progress_text(ev)
                    if text:
                        progress_pending.append(text)
                seen_event_id=newest
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
                    if progress_pending:
                        pending=''.join(progress_pending).strip()
                        progress_pending=[]
                        if pending and pending != final_summary:
                            task_send(pending[:1800],'progress:'+str(seen_event_id),final_event)
                    task_send(final_summary,'final',final_event)
                else:
                    task_send('公司 Codex 完成'+fleet_task_visibility_note(task_id)+'：\n'+final_summary,'final',final_event)
                return
            task=fleet_task_status(task_id) or {}; status=str(task.get('status') or '').strip(); last=status or last
            if status in ('completed','error','cancelled'):
                summary=' '.join(str(task.get('last_summary') or final_summary or '').split()).strip()
                if feishu_chat:
                    if progress_pending:
                        task_send(''.join(progress_pending).strip()[:1800],'progress:'+str(seen_event_id),final_event); progress_pending=[]
                    if status=='completed': task_send(summary or '已完成。','completed',final_event)
                    elif status=='cancelled': task_send('任务已取消：'+str(task_id),'cancelled',final_event)
                    else: task_send('任务失败：'+(summary or str(task_id)),'error',final_event)
                elif status=='completed': task_send('公司 Codex 完成'+fleet_task_visibility_note(task_id)+'：\n'+(summary or '已完成。'),'completed',final_event)
                elif status=='cancelled': task_send('公司 Codex 任务已取消：'+str(task_id),'cancelled',final_event)
                else: task_send('公司 Codex 任务失败：'+(summary or str(task_id)),'error',final_event)
                return
        except Exception as e:
            append(STATE/'server.log',f'{now()} fleet completion watcher failed task={task_id}: {e}')
        time.sleep(interval)
    task_send(f'公司 Codex 任务仍未完成：{task_id}，最后状态 {last or "unknown"}。可说“现在状态”查看。','timeout')

'''


MIRROR_FUNCTION = r'''def send_feishu_session_mirror(chat_id, message, event=None):
    target=normalize_feishu_chat_id('feishu',chat_id,'')
    event_id=(event or {}).get('event_id') if isinstance(event,dict) else None
    session_id=(event or {}).get('session_id') if isinstance(event,dict) else None
    if not target:
        return {'ts':now(),'rc':2,'error':'missing feishu chat target','message':str(message)}
    key=f'fleet-session:{event_id}:{target}' if event_id else f'fleet-session:{session_id}:{target}:{hash_text(message)}'
    rec=enqueue_outbound_message(key,message,channel='feishu',account='default',target=target,event=event)
    rec['event_id']=event_id
    rec['session_id']=session_id
    append(STATE/'feishu-session-mirror.log',json.dumps(rec,ensure_ascii=False))
    return rec

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
    backup = path.with_name(path.name + f".bak-outbound-queue-{stamp}")
    shutil.copy2(path, backup)

    text = text.replace(
        "RUNS_STATE={}; PROCS={}; CANCELLED=set(); LOCK=threading.Lock(); SEND_LOCK=threading.Lock()\n"
        "DIRECT_FLEET_NO_REPLY='__codex_fleet_no_reply__'\n",
        "RUNS_STATE={}; PROCS={}; CANCELLED=set(); LOCK=threading.Lock(); SEND_LOCK=threading.Lock(); "
        "OUTBOUND_QUEUE_LOCK=threading.Lock(); OUTBOUND_QUEUE_WAKE=queue.Queue(maxsize=1)\n"
        "DIRECT_FLEET_NO_REPLY='__codex_fleet_no_reply__'\n"
        "OUTBOUND_QUEUE_DB=STATE/'outbound-message-queue.sqlite3'; OUTBOUND_QUEUE_LOG=STATE/'outbound-message-queue.log'\n",
    )
    if "def outbound_queue_conn():" not in text:
        text = text.replace("def send_full(prefix,payload,run_dir=None):\n", QUEUE_BLOCK + "def send_full(prefix,payload,run_dir=None):\n")

    text = replace_between(text, "def watch_fleet_task_completion(task_id, item, run_dir=None):\n", "def start_fleet_completion_watcher", WATCH_FUNCTION)
    text = replace_between(text, "def send_feishu_session_mirror(chat_id, message, event=None):\n", "def feishu_session_mirror_text", MIRROR_FUNCTION)
    text = text.replace(
        "if path=='/health': return self._json(200,{'ok':True,'ts':now(),'model':MODEL,'state':str(STATE),'target':TARGET})",
        "if path=='/health': return self._json(200,{'ok':True,'ts':now(),'model':MODEL,'state':str(STATE),'target':TARGET,'outbound_queue':outbound_queue_stats()})",
    )
    text = text.replace(
        "recover_runs(); start_feishu_session_mirror_watcher(); srv=ThreadingHTTPServer((args.listen,args.port),Handler);",
        "recover_runs(); start_outbound_dispatcher(); start_feishu_session_mirror_watcher(); srv=ThreadingHTTPServer((args.listen,args.port),Handler);",
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
