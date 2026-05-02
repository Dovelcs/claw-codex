#!/usr/bin/env python3
import argparse
import json
import re
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def http_json(url, method="GET", body=None, headers=None, timeout=20):
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", **(headers or {})},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def load_feishu_config(path):
    data = json.load(open(path))
    cfg = (data.get("channels") or {}).get("feishu") or {}
    app_id = cfg.get("appId") or cfg.get("app_id")
    app_secret = cfg.get("appSecret") or cfg.get("app_secret")
    if not app_id or not app_secret:
        raise SystemExit("Feishu appId/appSecret not found in OpenClaw config")
    domain = str(cfg.get("domain") or "feishu").lower()
    base = "https://open.larksuite.com/open-apis" if "lark" in domain else "https://open.feishu.cn/open-apis"
    return {"app_id": app_id, "app_secret": app_secret, "base": base, "raw": data, "path": path}


def owner_open_id_from_config(cfg):
    owner = str((cfg.get("raw", {}).get("channels") or {}).get("feishu", {}).get("ownerOpenId") or "").strip()
    if owner:
        return owner
    groups = ((cfg.get("raw", {}).get("channels") or {}).get("feishu", {}).get("groups") or {})
    for group in groups.values():
        allow = group.get("allowFrom") if isinstance(group, dict) else None
        if isinstance(allow, list):
            for item in allow:
                value = str(item or "").strip()
                if value.startswith("ou_"):
                    return value
    return ""


def tenant_token(cfg):
    payload = {"app_id": cfg["app_id"], "app_secret": cfg["app_secret"]}
    data = http_json(cfg["base"] + "/auth/v3/tenant_access_token/internal", method="POST", body=payload)
    if int(data.get("code") or 0) != 0:
        raise SystemExit(f"Feishu token failed: {data.get('msg') or data}")
    return data["tenant_access_token"]


def safe_name(text, limit=36):
    text = " ".join(str(text or "").split())
    text = re.sub(r"[\r\n\t]+", " ", text)
    text = re.sub(r"[\[\]{}<>|]+", " ", text)
    return text[:limit].strip() or "untitled"


def cwd_alias(cwd):
    parts = [p for p in str(cwd or "").split("/") if p]
    if not parts:
        return "codex"
    if len(parts) >= 2 and parts[-2].lower() in {"rk3576", "rk3562", "rk3568", "android"}:
        return parts[-1]
    return parts[-1]


def group_name(number, session):
    sid = str(session.get("session_id") or "")[:8]
    project = safe_name(session.get("project_alias") or cwd_alias(session.get("cwd")) or "codex", 18)
    title = safe_name(session.get("title") or sid, 22)
    return safe_name(f"{project} {title}", 60)


def create_group(base, token, owner_open_id, name, description):
    body = {
        "name": name,
        "description": description,
        "user_id_list": [owner_open_id],
    }
    url = base + "/im/v1/chats?user_id_type=open_id"
    return http_json(url, method="POST", body=body, headers={"Authorization": "Bearer " + token}, timeout=25)


def send_message(base, token, chat_id, text):
    body = {
        "receive_id": chat_id,
        "msg_type": "text",
        "content": json.dumps({"text": text}, ensure_ascii=False),
    }
    url = base + "/im/v1/messages?receive_id_type=chat_id"
    return http_json(url, method="POST", body=body, headers={"Authorization": "Bearer " + token}, timeout=20)


def apply_openclaw_group_defaults(cfg, chat_ids, owner_open_id, dry_run=False):
    chat_ids = sorted({str(chat_id or "").strip() for chat_id in chat_ids if str(chat_id or "").strip().startswith("oc_")})
    if not chat_ids:
        return {}
    path = Path(cfg["path"])
    data = cfg["raw"]
    feishu = data.setdefault("channels", {}).setdefault("feishu", {})
    groups = feishu.setdefault("groups", {})
    allow = set(str(item) for item in feishu.get("groupAllowFrom") or [] if item)
    for chat_id in chat_ids:
        allow.add(chat_id)
        entry = groups.setdefault(chat_id, {})
        entry["requireMention"] = False
        if owner_open_id:
            entry["allowFrom"] = [owner_open_id]
    feishu["groupPolicy"] = "allowlist"
    feishu["groupAllowFrom"] = sorted(allow)
    feishu["requireMention"] = True
    feishu["topicSessionMode"] = "disabled"
    feishu["replyInThread"] = "disabled"
    if dry_run:
        return {"updated_groups": len(chat_ids), "dry_run": True}
    backup = path.with_name(path.name + ".bak-codex-group-defaults-" + time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, backup)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return {"updated_groups": len(chat_ids), "backup": str(backup)}


def load_state(path):
    if not path:
        return {"seen_session_ids": [], "pending_session_chats": {}}
    state_path = Path(path)
    if not state_path.exists():
        return {"seen_session_ids": [], "pending_session_chats": {}}
    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
    except Exception:
        return {"seen_session_ids": [], "pending_session_chats": {}}
    seen = data.get("seen_session_ids")
    if not isinstance(seen, list):
        seen = []
    pending = data.get("pending_session_chats")
    if not isinstance(pending, dict):
        pending = {}
    return {
        "seen_session_ids": [str(item) for item in seen if item],
        "pending_session_chats": {
            str(sid): str(chat_id)
            for sid, chat_id in pending.items()
            if str(sid) and str(chat_id).startswith("oc_")
        },
    }


def save_state(path, seen_session_ids, dry_run=False, pending_session_chats=None):
    pending_session_chats = pending_session_chats or {}
    if not path:
        return {
            "state_file": "",
            "seen_sessions": len(seen_session_ids),
            "pending_sessions": len(pending_session_chats),
            "dry_run": dry_run,
        }
    state_path = Path(path)
    result = {
        "state_file": str(state_path),
        "seen_sessions": len(seen_session_ids),
        "pending_sessions": len(pending_session_chats),
        "dry_run": dry_run,
    }
    if dry_run:
        return result
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(
        json.dumps(
            {
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "seen_session_ids": sorted(seen_session_ids),
                "pending_session_chats": dict(sorted(pending_session_chats.items())),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return result


def allowed_sources(values):
    allowed = []
    for value in values or []:
        allowed.extend(item.strip() for item in str(value).split(","))
    return {item for item in allowed if item}


def run_once(args):
    if args.session_id and args.new_sessions_only:
        raise SystemExit("--session-id cannot be combined with --new-sessions-only")
    manager = args.manager.rstrip("/")
    cfg = load_feishu_config(args.config)
    owner_open_id = args.owner_open_id or owner_open_id_from_config(cfg)
    if not owner_open_id:
        raise SystemExit("owner open_id missing; pass --owner-open-id or configure an existing group allowFrom")

    bindings = http_json(manager + "/api/chat-bindings?channel=feishu").get("bindings") or []
    group_chat_ids = {
        str(b.get("chat_id") or "")
        for b in bindings
        if str(b.get("chat_id") or "").startswith("oc_")
    }
    apply_result = {}
    if not args.new_sessions_only:
        apply_result = apply_openclaw_group_defaults(cfg, group_chat_ids, owner_open_id, args.dry_run)
    project_by_session = {}
    for b in bindings:
        sid = str(b.get("session_id") or "")
        project = str(b.get("project_alias") or "")
        if sid and project and sid not in project_by_session:
            project_by_session[sid] = project
    sessions = http_json(manager + f"/api/sessions?limit={max(args.limit, args.start)}").get("sessions") or []
    for s in sessions:
        sid = str(s.get("session_id") or "")
        if sid in project_by_session and not s.get("project_alias"):
            s["project_alias"] = project_by_session[sid]
    sources = allowed_sources(args.source)
    if sources and not args.session_id:
        sessions = [s for s in sessions if str(s.get("source") or "") in sources]
    state = load_state(args.state_file) if args.new_sessions_only else {"seen_session_ids": [], "pending_session_chats": {}}
    seen_session_ids = set(state.get("seen_session_ids") or [])
    pending_session_chats = dict(state.get("pending_session_chats") or {})
    known_session_ids = {str(s.get("session_id") or "") for s in sessions if str(s.get("session_id") or "")}
    pending_session_chats = {
        sid: chat_id for sid, chat_id in pending_session_chats.items()
        if sid in known_session_ids
    }
    state_result = {}

    if args.session_id:
        sessions = [s for s in sessions if str(s.get("session_id") or "") == args.session_id]
        if not sessions:
            raise SystemExit(f"session not found in manager session list: {args.session_id}")
    elif args.new_sessions_only:
        if not seen_session_ids:
            state_result = save_state(args.state_file, known_session_ids, args.dry_run)
            return {
                "created": [],
                "skipped": [],
                "failed": [],
                "openclaw_group_defaults": apply_result,
                "state": {**state_result, "baselined": True},
            }
        sessions = [s for s in sessions if str(s.get("session_id") or "") not in seen_session_ids]
    else:
        sessions = sessions[max(args.start - 1, 0):max(args.start - 1, 0) + args.limit]
    existing_by_session = {
        str(b.get("session_id")): b
        for b in bindings
        if str(b.get("session_id") or "") and str(b.get("chat_id") or "").startswith("oc_")
    }

    token = None
    created = []
    skipped = []
    failed = []
    new_chat_ids = []
    seen_after_success = set(seen_session_ids)
    pending_after = dict(pending_session_chats)

    for offset, session in enumerate(sessions, args.start):
        sid = str(session.get("session_id") or "")
        if not sid:
            continue
        if sid in existing_by_session:
            skipped.append({"number": offset, "session_id": sid, "chat_id": existing_by_session[sid].get("chat_id")})
            seen_after_success.add(sid)
            pending_after.pop(sid, None)
            continue
        name = group_name(offset, session)
        desc = f"Codex session {sid}\nsource={session.get('source') or ''}\ncwd={session.get('cwd') or ''}"
        if args.dry_run:
            created.append({"number": offset, "session_id": sid, "name": name, "dry_run": True})
            continue
        try:
            pending_chat_id = pending_after.get(sid)
            if pending_chat_id:
                http_json(
                    manager + "/api/session-chats/bind",
                    method="POST",
                    body={
                        "channel": "feishu",
                        "chat_id": pending_chat_id,
                        "profile": args.profile,
                        "session_selector": sid,
                        "session_policy": "fixed-session",
                    },
                )
                skipped.append({"number": offset, "session_id": sid, "chat_id": pending_chat_id, "pending_bound": True})
                new_chat_ids.append(pending_chat_id)
                seen_after_success.add(sid)
                pending_after.pop(sid, None)
                continue
            if token is None:
                token = tenant_token(cfg)
            resp = create_group(cfg["base"], token, owner_open_id, name, desc)
            if int(resp.get("code") or 0) != 0:
                failed.append({"number": offset, "session_id": sid, "name": name, "error": resp.get("msg") or resp})
                continue
            chat_id = (resp.get("data") or {}).get("chat_id")
            if not chat_id:
                failed.append({"number": offset, "session_id": sid, "name": name, "error": "missing chat_id"})
                continue
            bind = {
                "channel": "feishu",
                "chat_id": chat_id,
                "profile": args.profile,
                "session_selector": sid,
                "session_policy": "fixed-session",
            }
            try:
                http_json(manager + "/api/session-chats/bind", method="POST", body=bind)
            except Exception as e:
                if args.new_sessions_only:
                    pending_after[sid] = chat_id
                failed.append({"number": offset, "session_id": sid, "chat_id": chat_id, "name": name, "error": f"bind failed: {e!r}"})
                continue
            if not args.no_intro:
                try:
                    send_message(
                        cfg["base"],
                        token,
                        chat_id,
                        f"已绑定 Codex 会话: {sid[:13]}\n普通消息会发送到这个会话。",
                    )
                except Exception as e:
                    failed.append({"number": offset, "session_id": sid, "chat_id": chat_id, "name": name, "error": f"intro failed: {e!r}"})
            created.append({"number": offset, "session_id": sid, "chat_id": chat_id, "name": name})
            new_chat_ids.append(chat_id)
            seen_after_success.add(sid)
            pending_after.pop(sid, None)
            time.sleep(0.2)
        except urllib.error.HTTPError as e:
            failed.append({"number": offset, "session_id": sid, "name": name, "error": e.read().decode(errors="replace")[:500]})
        except Exception as e:
            failed.append({"number": offset, "session_id": sid, "name": name, "error": repr(e)})
    if new_chat_ids:
        fresh_cfg = load_feishu_config(args.config)
        apply_result = apply_openclaw_group_defaults(fresh_cfg, group_chat_ids | set(new_chat_ids), owner_open_id, False)
    if args.new_sessions_only:
        state_result = save_state(args.state_file, seen_after_success, args.dry_run, pending_after)

    return {
        "created": created,
        "skipped": skipped,
        "failed": failed,
        "openclaw_group_defaults": apply_result,
        "state": state_result,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manager", default="http://100.106.225.53:18992")
    ap.add_argument("--config", default="/data/state/openclaw.json")
    ap.add_argument("--owner-open-id", default="")
    ap.add_argument("--profile", default="")
    ap.add_argument("--limit", type=int, default=200)
    ap.add_argument("--start", type=int, default=1)
    ap.add_argument("--session-id", default="", help="Provision only the exact manager session id.")
    ap.add_argument("--source", action="append", default=[], help="Only provision sessions whose source matches this value. May be repeated or comma-separated.")
    ap.add_argument("--new-sessions-only", action="store_true", help="Only provision sessions not already recorded in --state-file.")
    ap.add_argument("--state-file", default="", help="JSON state file used with --new-sessions-only.")
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--interval", type=float, default=10)
    ap.add_argument("--no-intro", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    while True:
        result = run_once(args)
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        if not args.loop:
            break
        time.sleep(max(10, args.interval))


if __name__ == "__main__":
    main()
