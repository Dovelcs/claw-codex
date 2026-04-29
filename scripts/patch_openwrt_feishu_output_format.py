#!/usr/bin/env python3
"""Patch OpenWrt bridge Feishu outbound text formatting."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


FORMAT_BLOCK = r'''
def clean_feishu_inline_text(value):
    value=re.sub(r'\*\*([^*\n]+)\*\*', r'\1', str(value or ''))
    value=re.sub(r'__([^_\n]+)__', r'\1', value)
    value=value.replace('`','')
    value=re.sub(r'\s+', ' ', value)
    return value.strip()

def is_markdown_table_separator_cell(value):
    return bool(re.fullmatch(r':?-{2,}:?', clean_feishu_inline_text(value)))

def parse_markdown_table_message(message):
    text=str(message or '').strip()
    sep=re.search(r'\|\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|', text)
    if not sep:
        return None

    pipe_positions=[m.start() for m in re.finditer(r'\|', text)]
    cells=[]
    for left,right in zip(pipe_positions,pipe_positions[1:]):
        value=clean_feishu_inline_text(text[left+1:right])
        if not value:
            continue
        cells.append({'left':left,'right':right,'value':value})
    if len(cells) < 5:
        return None

    sep_start=-1
    sep_end=-1
    for idx,cell in enumerate(cells):
        if cell['left'] < sep.start() or cell['right'] > sep.end():
            continue
        if not is_markdown_table_separator_cell(cell['value']):
            continue
        end=idx
        while end < len(cells) and cells[end]['left'] >= sep.start() and cells[end]['right'] <= sep.end() and is_markdown_table_separator_cell(cells[end]['value']):
            end+=1
        if end-idx >= 2:
            sep_start=idx
            sep_end=end
            break
    if sep_start < 0:
        return None

    column_count=sep_end-sep_start
    if sep_start < column_count:
        return None
    header_cells=cells[sep_start-column_count:sep_start]
    headers=[item['value'] for item in header_cells]
    body_cells=cells[sep_end:]
    if not headers or not body_cells:
        return None

    rows=[]
    row_cell_groups=[]
    for idx in range(0,len(body_cells),column_count):
        group=body_cells[idx:idx+column_count]
        if len(group) != column_count:
            continue
        if any(item['value'].startswith('```') for item in group):
            break
        rows.append([item['value'] for item in group])
        row_cell_groups.append(group)
    if not rows:
        return None
    table_start=header_cells[0]['left']
    table_end=row_cell_groups[-1][-1]['right']
    prefix=text[:table_start].strip()
    suffix=text[table_end+1:].strip()
    return {'prefix':prefix,'suffix':suffix,'headers':headers,'rows':rows,'column_count':column_count,'table_start':table_start,'table_end':table_end}

def markdown_table_to_feishu_text(text):
    parsed=parse_markdown_table_message(text)
    if not parsed:
        return text, False
    prefix=parsed.get('prefix') or ''
    headers=parsed.get('headers') or []
    rows=parsed.get('rows') or []

    out=[]
    for row in rows:
        title=row[0]
        if not title:
            continue
        out.append('- '+title)
        for idx,cell in enumerate(row[1:], start=1):
            if not cell:
                continue
            header=headers[idx] if idx < len(headers) and headers[idx] else f'列{idx+1}'
            out.append(f'  {header}：{cell}')
    if not out:
        return text, False
    converted='\n'.join(out)
    if prefix:
        converted=prefix+'\n'+converted
    suffix=parsed.get('suffix') or ''
    if suffix:
        converted=converted+'\n'+suffix
    return converted, True

def feishu_card_text(value, limit=160):
    text=clean_feishu_inline_text(value)
    if len(text) > limit:
        text=text[:limit-1]+'…'
    return text

def normalize_feishu_card_markdown(value):
    text=str(value or '').strip()
    if not text:
        return ''
    labels='普通文本|表格|代码|行内代码|链接|列表|编号列表|引用|强调|任务列表'
    text=re.sub(r'([：:])\s+('+labels+r')：', r'\1\n\2：', text)
    text=re.sub(r'\s+('+labels+r')：', r'\n\1：', text)
    text=re.sub(r'```([A-Za-z0-9_+.-]*)\s+([^`\n][\s\S]*?)\s+```', lambda m: '```'+m.group(1)+'\n'+m.group(2).strip()+'\n```', text)
    text=re.sub(r'(代码：)\s*```', r'\1\n```', text)
    text=re.sub(r'```\s*(行内代码：|链接：|列表：|编号列表：|引用：|强调：|任务列表：)', r'```\n\1', text)
    text=re.sub(r'(列表：)\s*-\s+', r'\1\n- ', text)
    text=re.sub(r'(任务列表：)\s*-\s+(\[[ xX]\])\s+', r'\1\n- \2 ', text)
    text=re.sub(r'(编号列表：)\s*([0-9]{1,2})[.、]\s+', r'\1\n\2. ', text)
    text=re.sub(r'(引用：)\s*>\s+', r'\1\n> ', text)
    text=re.sub(r'(?<!^)(?<!\n)\s+-\s+(\[[ xX]\])\s+', r'\n- \1 ', text)
    text=re.sub(r'(?<!^)(?<!\n)\s+-\s+', r'\n- ', text)
    text=re.sub(r'(?<!^)(?<!\n)\s+([0-9]{1,2})[.、]\s+', r'\n\1. ', text)
    text=re.sub(r'\n{3,}', '\n\n', text)
    lines=[line.rstrip() for line in text.splitlines()]
    return '\n'.join(lines).strip()

def feishu_card_markdown(value, limit=1800):
    text=normalize_feishu_card_markdown(value)
    if not text:
        return ''
    if len(text) > limit:
        text=text[:limit-1]+'…'
    return text

def build_feishu_table_card(message):
    parsed=parse_markdown_table_message(message)
    if not parsed:
        return None
    headers=[feishu_card_text(h,40) or f'列{i+1}' for i,h in enumerate(parsed.get('headers') or [])]
    rows=parsed.get('rows') or []
    if not headers or not rows:
        return None
    columns=[]
    for idx,header in enumerate(headers[:12]):
        columns.append({
            'name':f'col_{idx}',
            'display_name':header,
            'data_type':'text',
            'width':'auto',
            'vertical_align':'top',
            'horizontal_align':'left',
        })
    card_rows=[]
    for row in rows[:50]:
        item={}
        for idx,_header in enumerate(headers[:12]):
            item[f'col_{idx}']=feishu_card_text(row[idx] if idx < len(row) else '',260)
        card_rows.append(item)
    if not card_rows:
        return None
    title='Codex 输出' if parsed.get('prefix') or parsed.get('suffix') else 'Codex 表格'
    elements=[]
    prefix=feishu_card_markdown(parsed.get('prefix') or '')
    suffix=feishu_card_markdown(parsed.get('suffix') or '')
    if prefix:
        elements.append({'tag':'markdown','content':prefix})
    elements.append({
        'tag':'table',
        'page_size':min(10,max(1,len(card_rows))),
        'row_height':'auto',
        'freeze_first_column':len(columns) > 2,
        'header_style':{
            'text_align':'left',
            'text_size':'normal',
            'background_style':'grey',
            'text_color':'default',
            'bold':True,
            'lines':1,
        },
        'columns':columns,
        'rows':card_rows,
    })
    if suffix:
        elements.append({'tag':'markdown','content':suffix})
    return {
        'schema':'2.0',
        'config':{'wide_screen_mode':True},
        'header':{
            'template':'blue',
            'title':{'tag':'plain_text','content':title},
        },
        'body':{
            'direction':'vertical',
            'elements':elements,
        },
    }

def format_feishu_outbound_text(message):
    text=str(message or '').strip()
    if not text:
        return text
    text, table_converted=markdown_table_to_feishu_text(text)
    text=re.sub(r'\*\*([^*\n]+)\*\*', r'\1', text)
    text=re.sub(r'__([^_\n]+)__', r'\1', text)
    text=text.replace('`','')
    if not table_converted:
        text=re.sub(r'[ \t]+', ' ', text)
        text=re.sub(r'\s*([。；;])\s*([0-9]{1,2})[.、]\s+', r'\1\n\2. ', text)
        text=re.sub(r'(?<!^)(?<!\n)\s+([0-9]{1,2})[.、]\s+', r'\n\1. ', text)
        text=re.sub(r'(?<!^)(?<!\n)\s+[-•]\s+', r'\n- ', text)
    text=re.sub(r'\n{3,}', '\n\n', text)
    lines=[]
    for raw in text.splitlines():
        if not raw.strip():
            if lines and lines[-1]:
                lines.append('')
            continue
        line=raw.rstrip() if raw.startswith('  ') else raw.strip()
        m=re.match(r'^([0-9]{1,2})[.、]\s*(.+)$', line)
        if m:
            lines.append(f'{m.group(1)}. {m.group(2).strip()}')
        else:
            lines.append(line)
    return '\n'.join(lines).strip()

'''


SEND_BLOCK = r'''def send_feishu_api(msg,target,account='default'):
    token,cfg=feishu_tenant_token(account)
    receive_id_type='chat_id' if str(target or '').startswith('oc_') else 'open_id'
    url=feishu_api_base(cfg.get('domain')) + '/im/v1/messages?receive_id_type=' + receive_id_type

    def post_message(body):
        req=urllib.request.Request(url,data=json.dumps(body,ensure_ascii=False).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+token},method='POST')
        with urllib.request.urlopen(req,timeout=20) as resp:
            return json.loads(resp.read().decode())

    original_msg=str(msg)
    card=build_feishu_table_card(original_msg)
    if card:
        body={'receive_id':target,'msg_type':'interactive','content':json.dumps(card,ensure_ascii=False)}
        try:
            payload=post_message(body)
            ok=int(payload.get('code') or 0) == 0
            if ok:
                data=payload.get('data') or {}
                message_id=data.get('message_id') or data.get('messageId') or ''
                rec_payload={'ok':True,'channel':'feishu','action':'send','messageId':message_id,'chatId':target,'fastApi':True,'msgType':'interactive','cardTable':True}
                return {'ts':now(),'rc':0,'channel':'feishu','account':account,'target':target,'stdout':json.dumps({'payload':rec_payload},ensure_ascii=False),'stderr':'','message':format_feishu_outbound_text(original_msg),'card':card,'fast_api':True}
            card_error=str(payload.get('msg') or payload)
        except Exception as e:
            card_error=repr(e)
    else:
        card_error=''

    text=format_feishu_outbound_text(original_msg)
    content=json.dumps({'text':text},ensure_ascii=False)
    body={'receive_id':target,'msg_type':'text','content':content}
    payload=post_message(body)
    ok=int(payload.get('code') or 0) == 0
    data=payload.get('data') or {}
    message_id=data.get('message_id') or data.get('messageId') or ''
    rec_payload={'ok':ok,'channel':'feishu','action':'send','messageId':message_id,'chatId':target,'fastApi':True,'msgType':'text'}
    if card_error:
        rec_payload['cardFallbackError']=card_error
    rc=0 if ok else 1
    return {'ts':now(),'rc':rc,'channel':'feishu','account':account,'target':target,'stdout':json.dumps({'payload':rec_payload},ensure_ascii=False),'stderr':'','message':text,'fast_api':True}

'''


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-feishu-format-{stamp}")
    shutil.copy2(path, backup)

    if "def format_feishu_outbound_text(" in text:
        start = text.find("def clean_feishu_inline_text(")
        if start < 0:
            start = text.find("def markdown_table_to_feishu_text(")
        if start < 0:
            start = text.find("def format_feishu_outbound_text(")
        end = text.find("def hash_text(value):\n", start)
        if end < 0:
            raise RuntimeError(f"hash_text marker not found after formatter in {path}")
        text = text[:start] + FORMAT_BLOCK + text[end:]
    else:
        text = text.replace("def hash_text(value):\n", FORMAT_BLOCK + "def hash_text(value):\n")

    send_start = text.find("def send_feishu_api(")
    send_end = text.find("def send_openclaw_channel(", send_start)
    if send_start < 0 or send_end < 0:
        raise RuntimeError(f"send_feishu_api/send_openclaw_channel marker not found in {path}")
    text = text[:send_start] + SEND_BLOCK + text[send_end:]

    text = text.replace(
        "return send_feishu_api(format_feishu_outbound_text(row.get('message') or ''),row.get('target') or '',row.get('account') or 'default')",
        "return send_feishu_api(row.get('message') or '',row.get('target') or '',row.get('account') or 'default')",
    )
    text = text.replace(
        "rec=send_feishu_api(format_feishu_outbound_text(msg),target,account)",
        "rec=send_feishu_api(msg,target,account)",
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
