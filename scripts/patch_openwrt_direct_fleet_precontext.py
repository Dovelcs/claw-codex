#!/usr/bin/env python3
"""Patch OpenWrt bridge to route direct fleet messages before context creation."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


OLD_BLOCK = """    ctx=ensure_context(sk,prompt) if sk else None
    resume_thread=(ctx or {}).get('codex_thread_id')
    effective_prompt=prompt if resume_thread else build_effective_prompt(sk,prompt)
    effective_prompt='请完成用户任务。微信侧任务生命周期消息由系统外层处理；你的最终回答直接给任务结果。\\n\\n'+effective_prompt
    (rdir/'prompt.txt').write_text(prompt,encoding='utf-8')
    (rdir/'effective-prompt.txt').write_text(effective_prompt,encoding='utf-8')
    meta={'run_id':rid,'started_at':now(),'model':model,'workdir':workdir,'codex_home':home,'session_key':sk,'channel':channel,'chat_id':chat_id,'parent_run_id':payload.get('parent_run_id'),'correction_of':payload.get('correction_of'),'created_by':payload.get('created_by','bridge'),'danger':danger,'skip_git_repo_check':skip,'extra_args':extra,'context_id':(ctx or {}).get('id'),'context_summary':(ctx or {}).get('summary'),'display_prompt':display_prompt,'wechat_dry_run':bool(payload.get('wechat_dry_run')),'human_stage':'','human_stage_seq':0,'human_started_at':'','human_finished_at':'','human_sent_stages':[],'human_continue_limit':int(os.environ.get('CODEX_BRIDGE_HUMAN_CONTINUE_LIMIT','0')),'status':'running','active':True}
    write_json(rdir/'meta.json',meta)
    with LOCK: RUNS_STATE[rid]=meta.copy()
    if sk: bind_session(sk,active_run_id=rid,active_codex_run_id=rid,last_run_id=rid)
    if cancel_requested(rid):
        meta.update({'status':'cancelled','finished_at':now(),'active':False})
        write_json(rdir/'meta.json',meta)
        with LOCK: RUNS_STATE[rid]=meta.copy()
        emit_lifecycle(meta,rdir,'任务结束','任务已取消。',final=True,dedupe=False)
        return
    try:
        direct_answer=try_direct_fleet_answer(display_prompt or prompt,sk,rdir,channel,chat_id)
    except Exception as e:
        append(rdir/'stderr.log',f'direct fleet fastpath failed: {e}')
        direct_answer=''
    if direct_answer:
        meta.update({'status':'completed','finished_at':now(),'active':False,'direct_fleet':True})
        write_json(rdir/'meta.json',meta)
        with LOCK: RUNS_STATE[rid]=meta.copy()
        if sk:
            bind_session(sk,active_run_id='',active_codex_run_id='',last_run_id=rid)
        if direct_answer != DIRECT_FLEET_NO_REPLY:
            emit_lifecycle(meta,rdir,'任务结束',direct_answer,final=True,dedupe=False)
        return
    emit_lifecycle(meta,rdir,'任务开始',task_start_message(display_prompt),dedupe=False)
"""


NEW_BLOCK = """    (rdir/'prompt.txt').write_text(prompt,encoding='utf-8')
    direct_meta={'run_id':rid,'started_at':now(),'model':model,'workdir':workdir,'codex_home':home,'session_key':sk,'channel':channel,'chat_id':chat_id,'parent_run_id':payload.get('parent_run_id'),'correction_of':payload.get('correction_of'),'created_by':payload.get('created_by','bridge'),'danger':danger,'skip_git_repo_check':skip,'extra_args':extra,'context_id':'','context_summary':'','display_prompt':display_prompt,'wechat_dry_run':bool(payload.get('wechat_dry_run')),'human_stage':'','human_stage_seq':0,'human_started_at':'','human_finished_at':'','human_sent_stages':[],'human_continue_limit':int(os.environ.get('CODEX_BRIDGE_HUMAN_CONTINUE_LIMIT','0')),'status':'running','active':True}
    write_json(rdir/'meta.json',direct_meta)
    with LOCK: RUNS_STATE[rid]=direct_meta.copy()
    if cancel_requested(rid):
        direct_meta.update({'status':'cancelled','finished_at':now(),'active':False})
        write_json(rdir/'meta.json',direct_meta)
        with LOCK: RUNS_STATE[rid]=direct_meta.copy()
        emit_lifecycle(direct_meta,rdir,'任务结束','任务已取消。',final=True,dedupe=False)
        return
    try:
        direct_answer=try_direct_fleet_answer(display_prompt or prompt,sk,rdir,channel,chat_id)
    except Exception as e:
        append(rdir/'stderr.log',f'direct fleet fastpath failed: {e}')
        direct_answer=''
    if direct_answer:
        direct_meta.update({'status':'completed','finished_at':now(),'active':False,'direct_fleet':True})
        write_json(rdir/'meta.json',direct_meta)
        with LOCK: RUNS_STATE[rid]=direct_meta.copy()
        if direct_answer != DIRECT_FLEET_NO_REPLY:
            emit_lifecycle(direct_meta,rdir,'任务结束',direct_answer,final=True,dedupe=False)
        return
    ctx=ensure_context(sk,prompt) if sk else None
    resume_thread=(ctx or {}).get('codex_thread_id')
    effective_prompt=prompt if resume_thread else build_effective_prompt(sk,prompt)
    effective_prompt='请完成用户任务。微信侧任务生命周期消息由系统外层处理；你的最终回答直接给任务结果。\\n\\n'+effective_prompt
    (rdir/'effective-prompt.txt').write_text(effective_prompt,encoding='utf-8')
    meta={'run_id':rid,'started_at':direct_meta.get('started_at') or now(),'model':model,'workdir':workdir,'codex_home':home,'session_key':sk,'channel':channel,'chat_id':chat_id,'parent_run_id':payload.get('parent_run_id'),'correction_of':payload.get('correction_of'),'created_by':payload.get('created_by','bridge'),'danger':danger,'skip_git_repo_check':skip,'extra_args':extra,'context_id':(ctx or {}).get('id'),'context_summary':(ctx or {}).get('summary'),'display_prompt':display_prompt,'wechat_dry_run':bool(payload.get('wechat_dry_run')),'human_stage':'','human_stage_seq':0,'human_started_at':'','human_finished_at':'','human_sent_stages':[],'human_continue_limit':int(os.environ.get('CODEX_BRIDGE_HUMAN_CONTINUE_LIMIT','0')),'status':'running','active':True}
    write_json(rdir/'meta.json',meta)
    with LOCK: RUNS_STATE[rid]=meta.copy()
    if sk: bind_session(sk,active_run_id=rid,active_codex_run_id=rid,last_run_id=rid)
    emit_lifecycle(meta,rdir,'任务开始',task_start_message(display_prompt),dedupe=False)
"""


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-direct-fleet-precontext-{stamp}")
    shutil.copy2(path, backup)

    if "direct_meta={'run_id':rid" in text:
        print(f"unchanged {path}")
        backup.unlink(missing_ok=True)
        return
    if OLD_BLOCK not in text:
        raise RuntimeError(f"run_codex context/direct-fleet block marker not found in {path}")
    text = text.replace(OLD_BLOCK, NEW_BLOCK, 1)

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
