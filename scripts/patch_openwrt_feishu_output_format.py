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

def markdown_table_to_feishu_text(text):
    sep=re.search(r'\|\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|', text)
    if not sep:
        return text, False

    start=text.rfind('\n',0,sep.start())+1
    prefix=text[:start].rstrip()
    table_text=text[start:].strip()
    cells=[clean_feishu_inline_text(cell) for cell in table_text.split('|')]
    cells=[cell for cell in cells if cell]
    if len(cells) < 5:
        return text, False

    sep_start=-1
    sep_end=-1
    for idx,cell in enumerate(cells):
        if not is_markdown_table_separator_cell(cell):
            continue
        end=idx
        while end < len(cells) and is_markdown_table_separator_cell(cells[end]):
            end+=1
        if end-idx >= 2:
            sep_start=idx
            sep_end=end
            break
    if sep_start < 0:
        return text, False

    column_count=sep_end-sep_start
    if sep_start < column_count:
        return text, False
    headers=cells[sep_start-column_count:sep_start]
    body_cells=cells[sep_end:]
    if not headers or not body_cells:
        return text, False

    rows=[]
    for idx in range(0,len(body_cells),column_count):
        row=body_cells[idx:idx+column_count]
        if len(row) != column_count:
            continue
        rows.append(row)
    if not rows:
        return text, False

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
    return converted, True

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


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-feishu-format-{stamp}")
    shutil.copy2(path, backup)

    if "def format_feishu_outbound_text(" in text:
        start = text.find("def markdown_table_to_feishu_text(")
        if start < 0:
            start = text.find("def format_feishu_outbound_text(")
        end = text.find("def hash_text(value):\n", start)
        if end < 0:
            raise RuntimeError(f"hash_text marker not found after formatter in {path}")
        text = text[:start] + FORMAT_BLOCK + text[end:]
    else:
        text = text.replace("def hash_text(value):\n", FORMAT_BLOCK + "def hash_text(value):\n")

    text = text.replace(
        "return send_feishu_api(row.get('message') or '',row.get('target') or '',row.get('account') or 'default')",
        "return send_feishu_api(format_feishu_outbound_text(row.get('message') or ''),row.get('target') or '',row.get('account') or 'default')",
    )
    text = text.replace(
        "rec=send_feishu_api(msg,target,account)",
        "rec=send_feishu_api(format_feishu_outbound_text(msg),target,account)",
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
