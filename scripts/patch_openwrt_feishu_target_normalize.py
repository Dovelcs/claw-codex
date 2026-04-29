#!/usr/bin/env python3
"""Patch OpenWrt bridge Feishu target normalization for session-thread ids."""

from __future__ import annotations

import shutil
import time
from pathlib import Path


TARGETS = [
    Path("/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py"),
    Path("/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py"),
]


OLD = r'''def normalize_feishu_chat_id(channel='', chat_id='', session_key=''):
    cid=str(chat_id or '').strip() or str(session_key or '').strip()
    if not is_feishu_channel(channel):
        return cid
    m=re.search(r'(^|:)(?:group|chat):(oc_[A-Za-z0-9]+)($|:)', cid)
    if m:
        return m.group(2)
    if cid.startswith('oc_'):
        return cid
    m=re.search(r'(oc_[A-Za-z0-9]+)', cid)
    if m:
        return m.group(1)
    return cid
'''


NEW = r'''def normalize_feishu_chat_id(channel='', chat_id='', session_key=''):
    cid=str(chat_id or '').strip() or str(session_key or '').strip()
    if not is_feishu_channel(channel):
        return cid
    m=re.search(r'(^|:)(?:group|chat):(oc_[A-Za-z0-9]+)($|:)', cid)
    if m:
        return m.group(2)
    m=re.search(r'(^|:)(?:direct|user):((?:ou|on)_[A-Za-z0-9]+)($|:)', cid)
    if m:
        return m.group(2)
    if cid.startswith(('oc_','ou_','on_')):
        return cid
    m=re.search(r'((?:oc|ou|on)_[A-Za-z0-9]+)', cid)
    if m:
        return m.group(1)
    return cid
'''


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if OLD not in text:
        print(f"unchanged {path}")
        return
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-feishu-target-{stamp}")
    shutil.copy2(path, backup)
    path.write_text(text.replace(OLD, NEW), encoding="utf-8")
    print(f"patched {path}")
    print(f"backup {backup}")


def main() -> None:
    for target in TARGETS:
        if target.exists():
            patch_file(target)


if __name__ == "__main__":
    main()
