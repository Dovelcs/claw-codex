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
def format_feishu_outbound_text(message):
    text=str(message or '').strip()
    if not text:
        return text
    text=re.sub(r'\*\*([^*\n]+)\*\*', r'\1', text)
    text=re.sub(r'__([^_\n]+)__', r'\1', text)
    text=text.replace('`','')
    text=re.sub(r'[ \t]+', ' ', text)
    text=re.sub(r'\s*([。；;])\s*([0-9]{1,2})[.、]\s+', r'\1\n\2. ', text)
    text=re.sub(r'(?<!^)(?<!\n)\s+([0-9]{1,2})[.、]\s+', r'\n\1. ', text)
    text=re.sub(r'(?<!^)(?<!\n)\s+[-•]\s+', r'\n- ', text)
    text=re.sub(r'\n{3,}', '\n\n', text)
    lines=[]
    for raw in text.splitlines():
        line=raw.strip()
        if not line:
            if lines and lines[-1]:
                lines.append('')
            continue
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

    if "def format_feishu_outbound_text(" not in text:
        text = text.replace("def hash_text(value):\n", FORMAT_BLOCK + "def hash_text(value):\n")

    text = text.replace(
        "return send_feishu_api(row.get('message') or '',row.get('target') or '',row.get('account') or 'default')",
        "return send_feishu_api(format_feishu_outbound_text(row.get('message') or ''),row.get('target') or '',row.get('account') or 'default')",
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
