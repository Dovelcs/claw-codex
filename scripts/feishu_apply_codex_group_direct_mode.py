#!/usr/bin/env python3
import argparse
import json
import shutil
import time
import urllib.request
from pathlib import Path


def http_json(url, timeout=20):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.load(resp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manager", default="http://100.106.225.53:18992")
    ap.add_argument("--config", default="/data/state/openclaw.json")
    ap.add_argument("--owner-open-id", default="")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    manager = args.manager.rstrip("/")
    data = http_json(manager + "/api/chat-bindings?channel=feishu")
    group_bindings = [
        b for b in data.get("bindings", [])
        if str(b.get("chat_id") or "").startswith("oc_") and str(b.get("session_id") or "")
    ]
    group_ids = sorted({str(b["chat_id"]) for b in group_bindings})
    if not group_ids:
        raise SystemExit("no Feishu oc_ Codex group bindings found")

    path = Path(args.config)
    cfg = json.loads(path.read_text())
    feishu = cfg.setdefault("channels", {}).setdefault("feishu", {})
    old = {
        "groupPolicy": feishu.get("groupPolicy"),
        "requireMention": feishu.get("requireMention"),
        "groupAllowFrom_count": len(feishu.get("groupAllowFrom") or []),
        "groups_count": len(feishu.get("groups") or {}),
    }

    groups = feishu.setdefault("groups", {})
    for gid in group_ids:
        entry = groups.setdefault(gid, {})
        entry["requireMention"] = False
        if args.owner_open_id:
            entry["allowFrom"] = [args.owner_open_id]

    feishu["groupPolicy"] = "allowlist"
    feishu["groupAllowFrom"] = group_ids
    feishu["requireMention"] = True

    result = {
        "groups": len(group_ids),
        "old": old,
        "new": {
            "groupPolicy": feishu.get("groupPolicy"),
            "requireMention": feishu.get("requireMention"),
            "groupAllowFrom_count": len(feishu.get("groupAllowFrom") or []),
            "groups_count": len(feishu.get("groups") or {}),
        },
    }
    if args.dry_run:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    backup = path.with_name(path.name + ".bak-codex-groups-direct-" + time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, backup)
    path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    result["backup"] = str(backup)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
