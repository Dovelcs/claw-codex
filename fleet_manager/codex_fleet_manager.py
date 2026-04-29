#!/usr/bin/env python3
"""Small SQLite-backed control plane for home-Codex managed Codex workers."""

from __future__ import annotations

import argparse
import json
import os
import queue
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_json_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("content-length") or "0")
    if length <= 0:
        return {}
    return json.loads(handler.rfile.read(length).decode("utf-8"))


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    handler.send_response(status)
    handler.send_header("content-type", "application/json; charset=utf-8")
    handler.send_header("cache-control", "no-store")
    handler.send_header("content-length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def read_json(value: str | None, fallback: Any) -> Any:
    if not value:
        return fallback
    try:
        return json.loads(value)
    except Exception:
        return fallback


class FleetStore:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(db_path), check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("pragma journal_mode=wal")
        self.db.execute("pragma busy_timeout=5000")
        self.db.execute("pragma foreign_keys=on")
        self.lock = threading.RLock()
        self.init_schema()
        self.listeners: dict[str, queue.Queue[None]] = {}

    def init_schema(self) -> None:
        self.db.executescript(
            """
            create table if not exists endpoints (
              endpoint_id text primary key,
              label text,
              status text not null default 'offline',
              capabilities_json text not null default '{}',
              last_seen_at text,
              created_at text not null,
              updated_at text not null
            );
            create table if not exists projects (
              alias text primary key,
              endpoint_id text not null,
              path text not null,
              mode text not null default 'vscode',
              created_at text not null,
              updated_at text not null
            );
            create table if not exists sessions (
              session_id text primary key,
              endpoint_id text not null,
              source text not null default 'vscode',
              title text,
              cwd text,
              rollout_path text,
              status text,
              active_turn_id text,
              updated_at text not null
            );
            create table if not exists tasks (
              task_id text primary key,
              endpoint_id text not null,
              profile text,
              chat_channel text,
              chat_id text,
              project_alias text,
              session_id text,
              prompt text not null,
              mode text not null default 'vscode',
              status text not null default 'pending',
              last_summary text,
              created_at text not null,
              updated_at text not null
            );
            create table if not exists events (
              event_id integer primary key autoincrement,
              endpoint_id text,
              task_id text,
              session_id text,
              type text not null,
              message text,
              data_json text,
              created_at text not null
            );
            create table if not exists commands (
              command_id text primary key,
              endpoint_id text not null,
              task_id text,
              type text not null,
              payload_json text not null,
              status text not null default 'pending',
              created_at text not null,
              updated_at text not null
            );
            create table if not exists context (
              profile text primary key,
              project_alias text,
              session_id text,
              updated_at text not null
            );
            create table if not exists chat_bindings (
              channel text not null,
              chat_id text not null,
              profile text,
              endpoint_id text,
              project_alias text not null,
              session_id text,
              title text,
              session_policy text not null default 'project-default',
              created_at text not null,
              updated_at text not null,
              primary key(channel, chat_id)
            );
            """
        )
        self.ensure_column("tasks", "profile", "text")
        self.ensure_column("tasks", "chat_channel", "text")
        self.ensure_column("tasks", "chat_id", "text")
        self.ensure_column("chat_bindings", "session_id", "text")
        self.ensure_column("chat_bindings", "title", "text")
        self.ensure_column("sessions", "rollout_path", "text")
        self.db.commit()

    def ensure_column(self, table: str, column: str, definition: str) -> None:
        columns = {row["name"] for row in self.db.execute(f"pragma table_info({table})")}
        if column not in columns:
            self.db.execute(f"alter table {table} add column {column} {definition}")

    def register_endpoint(self, endpoint_id: str, label: str, capabilities: Any, sessions: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        with self.lock:
            return self._register_endpoint(endpoint_id, label, capabilities, sessions)

    def _register_endpoint(self, endpoint_id: str, label: str, capabilities: Any, sessions: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        ts = now()
        self.db.execute(
            """
            insert into endpoints(endpoint_id,label,status,capabilities_json,last_seen_at,created_at,updated_at)
            values(?,?,?,?,?,?,?)
            on conflict(endpoint_id) do update set
              label=excluded.label,status='online',capabilities_json=excluded.capabilities_json,
              last_seen_at=excluded.last_seen_at,updated_at=excluded.updated_at
            """,
            (endpoint_id, label, "online", json.dumps(capabilities or {}, ensure_ascii=False), ts, ts, ts),
        )
        if sessions is not None:
            self.upsert_sessions(endpoint_id, sessions)
        self.db.commit()
        return self.endpoint(endpoint_id) or {}

    def heartbeat(self, endpoint_id: str, sessions: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        with self.lock:
            return self._heartbeat(endpoint_id, sessions)

    def _heartbeat(self, endpoint_id: str, sessions: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        self.touch_endpoint(endpoint_id)
        if sessions is not None:
            self.upsert_sessions(endpoint_id, sessions)
        self.db.commit()
        return self.endpoint(endpoint_id) or {}

    def touch_endpoint(self, endpoint_id: str) -> None:
        ts = now()
        self.db.execute(
            "update endpoints set status='online',last_seen_at=?,updated_at=? where endpoint_id=?",
            (ts, ts, endpoint_id),
        )

    def upsert_sessions(self, endpoint_id: str, sessions: list[dict[str, Any]]) -> None:
        ts = now()
        for session in sessions:
            sid = str(session.get("id") or session.get("session_id") or "").strip()
            if not sid:
                continue
            self.db.execute(
                """
                insert into sessions(session_id,endpoint_id,source,title,cwd,rollout_path,status,active_turn_id,updated_at)
                values(?,?,?,?,?,?,?,?,?)
                on conflict(session_id) do update set
                  endpoint_id=excluded.endpoint_id,source=excluded.source,title=excluded.title,cwd=excluded.cwd,
                  rollout_path=coalesce(excluded.rollout_path,rollout_path),
                  status=coalesce(excluded.status,status),active_turn_id=excluded.active_turn_id,updated_at=excluded.updated_at
                """,
                (
                    sid,
                    endpoint_id,
                    str(session.get("source") or "vscode"),
                    session.get("title") or session.get("name") or session.get("preview"),
                    session.get("cwd"),
                    session.get("rolloutPath") or session.get("rollout_path"),
                    session.get("status"),
                    session.get("activeTurnId") or session.get("active_turn_id"),
                    ts,
                ),
            )

    def register_project(self, alias: str, endpoint_id: str, path: str, mode: str = "vscode") -> dict[str, Any]:
        with self.lock:
            return self._register_project(alias, endpoint_id, path, mode)

    def _register_project(self, alias: str, endpoint_id: str, path: str, mode: str = "vscode") -> dict[str, Any]:
        ts = now()
        self.db.execute(
            """
            insert into projects(alias,endpoint_id,path,mode,created_at,updated_at)
            values(?,?,?,?,?,?)
            on conflict(alias) do update set endpoint_id=excluded.endpoint_id,path=excluded.path,mode=excluded.mode,updated_at=excluded.updated_at
            """,
            (alias, endpoint_id, path, mode, ts, ts),
        )
        self.db.commit()
        return self.project(alias) or {}

    def use_project(self, profile: str, alias: str) -> dict[str, Any]:
        with self.lock:
            return self._use_project(profile, alias)

    def _use_project(self, profile: str, alias: str) -> dict[str, Any]:
        project = self.project(alias)
        if not project:
            raise KeyError(f"unknown project: {alias}")
        self.ensure_context(profile)
        self.db.execute("update context set project_alias=?,updated_at=? where profile=?", (alias, now(), profile))
        self.db.commit()
        return {"profile": profile, "project": project, "session": self.context(profile).get("session_id")}

    def use_session(self, profile: str, selector: str) -> dict[str, Any]:
        with self.lock:
            return self._use_session(profile, selector)

    def _use_session(self, profile: str, selector: str) -> dict[str, Any]:
        session = self.resolve_session(selector)
        if not session:
            raise KeyError(f"unknown session: {selector}")
        self.ensure_context(profile)
        self.db.execute("update context set session_id=?,updated_at=? where profile=?", (session["session_id"], now(), profile))
        self.db.commit()
        return {"profile": profile, "session": session, "project": self.context(profile).get("project_alias")}

    def clear_context(self, profile: str) -> dict[str, Any]:
        with self.lock:
            return self._clear_context(profile)

    def _clear_context(self, profile: str) -> dict[str, Any]:
        self.ensure_context(profile)
        self.db.execute("update context set project_alias=null,session_id=null,updated_at=? where profile=?", (now(), profile))
        self.db.commit()
        return self.context(profile)

    def create_task(self, profile: str, prompt: str, project_alias: str | None, session_selector: str | None, mode: str | None) -> dict[str, Any]:
        with self.lock:
            return self._create_task(profile, prompt, project_alias, session_selector, mode)

    def _create_task(
        self,
        profile: str,
        prompt: str,
        project_alias: str | None,
        session_selector: str | None,
        mode: str | None,
        chat_channel: str | None = None,
        chat_id: str | None = None,
    ) -> dict[str, Any]:
        ctx = self.context(profile)
        project = self.project(project_alias or ctx.get("project_alias") or "") if (project_alias or ctx.get("project_alias")) else None
        session = self.resolve_session(session_selector or ctx.get("session_id") or "") if (session_selector or ctx.get("session_id")) else None
        if not session and project:
            session = self.recent_project_session(project["alias"])
        endpoint_id = (session or {}).get("endpoint_id") or (project or {}).get("endpoint_id")
        if not endpoint_id:
            endpoint = self.first_online_endpoint()
            endpoint_id = endpoint["endpoint_id"] if endpoint else ""
        if not endpoint_id:
            raise RuntimeError("no online endpoint available")
        task_id = "task-" + uuid.uuid4().hex[:12]
        task_mode = mode or (project or {}).get("mode") or "vscode"
        ts = now()
        session_id = (session or {}).get("session_id")
        self.db.execute(
            """
            insert into tasks(task_id,endpoint_id,profile,chat_channel,chat_id,project_alias,session_id,prompt,mode,status,created_at,updated_at)
            values(?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (task_id, endpoint_id, profile, chat_channel, chat_id, (project or {}).get("alias"), session_id, prompt, task_mode, "queued", ts, ts),
        )
        payload = {
            "task_id": task_id,
            "prompt": prompt,
            "project": project,
            "session_id": session_id,
            "mode": task_mode,
        }
        self.enqueue_command(endpoint_id, task_id, "send", payload)
        self.add_event(endpoint_id, task_id, session_id, "task/queued", "task queued", payload)
        self.db.commit()
        self.notify(endpoint_id)
        return self.task(task_id) or {}

    def bind_chat(
        self,
        channel: str,
        chat_id: str,
        profile: str | None,
        project_alias: str,
        endpoint_id: str | None = None,
        session_policy: str = "project-default",
    ) -> dict[str, Any]:
        with self.lock:
            return self._bind_chat(channel, chat_id, profile, project_alias, endpoint_id, session_policy)

    def _bind_chat(
        self,
        channel: str,
        chat_id: str,
        profile: str | None,
        project_alias: str,
        endpoint_id: str | None = None,
        session_policy: str = "project-default",
    ) -> dict[str, Any]:
        channel = require_value(channel, "channel")
        chat_id = require_value(chat_id, "chat_id")
        project = self.project(project_alias)
        if not project:
            raise KeyError(f"unknown project: {project_alias}")
        endpoint_id = endpoint_id or project["endpoint_id"]
        ts = now()
        self.db.execute(
            """
            insert into chat_bindings(channel,chat_id,profile,endpoint_id,project_alias,session_id,title,session_policy,created_at,updated_at)
            values(?,?,?,?,?,?,?,?,?,?)
            on conflict(channel,chat_id) do update set
              profile=excluded.profile,endpoint_id=excluded.endpoint_id,project_alias=excluded.project_alias,
              session_id=excluded.session_id,title=excluded.title,
              session_policy=excluded.session_policy,updated_at=excluded.updated_at
            """,
            (channel, chat_id, profile, endpoint_id, project_alias, None, None, session_policy or "project-default", ts, ts),
        )
        self.db.commit()
        return self.chat_binding(channel, chat_id) or {}

    def bind_session_chat(
        self,
        channel: str,
        chat_id: str,
        profile: str | None,
        session_selector: str,
        project_alias: str | None = None,
        session_policy: str = "fixed-session",
    ) -> dict[str, Any]:
        with self.lock:
            channel = require_value(channel, "channel")
            chat_id = require_value(chat_id, "chat_id")
            session = self.resolve_session(require_value(session_selector, "session_selector"))
            if not session:
                raise KeyError(f"unknown session: {session_selector}")
            alias = project_alias or self.project_alias_for_session(session) or ""
            ts = now()
            self.db.execute(
                """
                insert into chat_bindings(channel,chat_id,profile,endpoint_id,project_alias,session_id,title,session_policy,created_at,updated_at)
                values(?,?,?,?,?,?,?,?,?,?)
                on conflict(channel,chat_id) do update set
                  profile=excluded.profile,endpoint_id=excluded.endpoint_id,project_alias=excluded.project_alias,
                  session_id=excluded.session_id,title=excluded.title,session_policy=excluded.session_policy,
                  updated_at=excluded.updated_at
                """,
                (
                    channel,
                    chat_id,
                    profile,
                    session["endpoint_id"],
                    alias,
                    session["session_id"],
                    session.get("title"),
                    session_policy or "fixed-session",
                    ts,
                    ts,
                ),
            )
            self.db.commit()
            return self.chat_binding(channel, chat_id) or {}

    def sync_session_chats(
        self,
        channel: str,
        owner_chat_id: str,
        profile: str | None = None,
        endpoint_id: str | None = None,
        project_alias: str | None = None,
        limit: int = 200,
    ) -> dict[str, Any]:
        with self.lock:
            channel = require_value(channel, "channel")
            owner_chat_id = require_value(owner_chat_id, "owner_chat_id")
            limit = max(1, min(int(limit or 200), 500))
            sessions = self.sessions(endpoint_id, project_alias)[:limit]
            mappings = []
            for number, session in enumerate(sessions, 1):
                sid = session["session_id"]
                chat_id = self.session_entry_chat_id(owner_chat_id, sid)
                binding = self.bind_session_chat(
                    channel,
                    chat_id,
                    profile or f"{channel}:{owner_chat_id}",
                    sid,
                    self.project_alias_for_session(session) or project_alias,
                    "fixed-session",
                )
                mappings.append({"number": number, "binding": binding, "session": session})
            return {"owner_chat_id": owner_chat_id, "channel": channel, "count": len(mappings), "mappings": mappings}

    def session_chats(self, channel: str, owner_chat_id: str, limit: int = 200) -> list[dict[str, Any]]:
        channel = require_value(channel, "channel")
        owner_chat_id = require_value(owner_chat_id, "owner_chat_id")
        limit = max(1, min(int(limit or 200), 500))
        prefix = self.session_entry_chat_id(owner_chat_id, "")
        rows = self.db.execute(
            """
            select cb.*, s.source, s.cwd, s.rollout_path, s.status, s.active_turn_id, s.updated_at as session_updated_at
            from chat_bindings cb
            left join sessions s on s.session_id=cb.session_id
            where cb.channel=? and cb.chat_id like ? and cb.session_id is not null
            order by s.updated_at desc, cb.session_id asc
            limit ?
            """,
            (channel, prefix + "%", limit),
        ).fetchall()
        return [{"number": index + 1, "binding": dict(row), "session": self.mapping_session_row(row)} for index, row in enumerate(rows)]

    def create_session_chat_task(self, channel: str, owner_chat_id: str, selector: str, prompt: str) -> dict[str, Any]:
        with self.lock:
            mapping = self.resolve_session_chat(channel, owner_chat_id, selector)
            if not mapping:
                raise KeyError(f"unknown mapped session: {selector}")
            task = self.create_chat_task(channel, mapping["binding"]["chat_id"], prompt)
            return {"mapping": mapping, "task": task}

    def unbind_chat(self, channel: str, chat_id: str) -> dict[str, Any]:
        with self.lock:
            channel = require_value(channel, "channel")
            chat_id = require_value(chat_id, "chat_id")
            binding = self.chat_binding(channel, chat_id)
            self.db.execute("delete from chat_bindings where channel=? and chat_id=?", (channel, chat_id))
            self.db.commit()
            return {"ok": True, "removed": bool(binding), "binding": binding}

    def create_chat_task(self, channel: str, chat_id: str, prompt: str) -> dict[str, Any]:
        with self.lock:
            binding = self.chat_binding(channel, chat_id)
            if not binding:
                raise KeyError(f"chat is not bound: {channel}:{chat_id}")
            profile = binding.get("profile") or f"{channel}:{chat_id}"
            return self._create_task(
                profile,
                prompt,
                binding.get("project_alias") or None,
                binding.get("session_id") or None,
                None,
                chat_channel=channel,
                chat_id=chat_id,
            )

    def chat_status(self, channel: str, chat_id: str) -> dict[str, Any]:
        binding = self.chat_binding(channel, chat_id)
        active = self.chat_active_task(channel, chat_id)
        recent = self.chat_tasks(channel, chat_id, 5)
        return {"binding": binding, "active_task": active, "recent_tasks": recent}

    def enqueue_stop(self, target: str) -> dict[str, Any]:
        with self.lock:
            return self._enqueue_stop(target)

    def _enqueue_stop(self, target: str) -> dict[str, Any]:
        task = self.task(target)
        session = None if task else self.resolve_session(target)
        if not task and not session:
            raise KeyError(f"unknown task or session: {target}")
        endpoint_id = (task or session)["endpoint_id"]
        task_id = (task or {}).get("task_id")
        session_id = (task or {}).get("session_id") or (session or {}).get("session_id")
        command = self.enqueue_command(endpoint_id, task_id, "stop", {"task_id": task_id, "session_id": session_id})
        self.add_event(endpoint_id, task_id, session_id, "task/cancel_requested", "cancel requested", command)
        self.db.commit()
        self.notify(endpoint_id)
        return command

    def enqueue_command(self, endpoint_id: str, task_id: str | None, command_type: str, payload: dict[str, Any]) -> dict[str, Any]:
        command_id = "cmd-" + uuid.uuid4().hex[:12]
        ts = now()
        self.db.execute(
            "insert into commands(command_id,endpoint_id,task_id,type,payload_json,status,created_at,updated_at) values(?,?,?,?,?,?,?,?)",
            (command_id, endpoint_id, task_id, command_type, json.dumps(payload, ensure_ascii=False), "pending", ts, ts),
        )
        return {"command_id": command_id, "endpoint_id": endpoint_id, "task_id": task_id, "type": command_type, "payload": payload, "status": "pending"}

    def poll_commands(self, endpoint_id: str, timeout: float) -> list[dict[str, Any]]:
        deadline = time.time() + timeout
        while True:
            commands = self.claim_commands(endpoint_id)
            if commands or time.time() >= deadline:
                return commands
            q = self.listeners.setdefault(endpoint_id, queue.Queue(maxsize=1))
            try:
                q.get(timeout=min(2.0, max(0.0, deadline - time.time())))
            except queue.Empty:
                pass

    def claim_commands(self, endpoint_id: str) -> list[dict[str, Any]]:
        with self.lock:
            return self._claim_commands(endpoint_id)

    def _claim_commands(self, endpoint_id: str) -> list[dict[str, Any]]:
        rows = self.db.execute(
            "select * from commands where endpoint_id=? and status='pending' order by created_at limit 10",
            (endpoint_id,),
        ).fetchall()
        ts = now()
        commands = []
        for row in rows:
            self.db.execute("update commands set status='claimed',updated_at=? where command_id=?", (ts, row["command_id"]))
            commands.append(self.command_row(row, "claimed"))
        self.db.commit()
        return commands

    def record_worker_events(self, endpoint_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            return self._record_worker_events(endpoint_id, payload)

    def _record_worker_events(self, endpoint_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        sessions = payload.get("sessions")
        if isinstance(sessions, list):
            self.upsert_sessions(endpoint_id, sessions)
        for result in payload.get("command_results") or []:
            self.record_command_result(result)
        for event in payload.get("events") or []:
            self.add_event(
                endpoint_id,
                event.get("task_id"),
                event.get("session_id"),
                event.get("type") or "worker/event",
                event.get("message"),
                event.get("data"),
            )
        self.touch_endpoint(endpoint_id)
        self.db.commit()
        return {"ok": True}

    def record_command_result(self, result: dict[str, Any]) -> None:
        command_id = result.get("command_id")
        status = "done" if result.get("ok", True) else "error"
        if command_id:
            self.db.execute("update commands set status=?,updated_at=? where command_id=?", (status, now(), command_id))
        task_id = result.get("task_id")
        if task_id:
            task_status = result.get("task_status") or ("running" if status == "done" else "error")
            self.db.execute(
                "update tasks set status=?,session_id=coalesce(?,session_id),last_summary=coalesce(?,last_summary),updated_at=? where task_id=?",
                (task_status, result.get("session_id"), result.get("summary"), now(), task_id),
            )

    def add_event(self, endpoint_id: str | None, task_id: str | None, session_id: str | None, event_type: str, message: str | None, data: Any) -> None:
        self.db.execute(
            "insert into events(endpoint_id,task_id,session_id,type,message,data_json,created_at) values(?,?,?,?,?,?,?)",
            (endpoint_id, task_id, session_id, event_type, message, json.dumps(data, ensure_ascii=False), now()),
        )
        if task_id and event_type in {"turn/completed", "task/completed"}:
            self.db.execute("update tasks set status='completed',last_summary=coalesce(?,last_summary),updated_at=? where task_id=?", (message, now(), task_id))
        if task_id and event_type in {"turn/aborted", "task/error"}:
            self.db.execute("update tasks set status='error',last_summary=coalesce(?,last_summary),updated_at=? where task_id=?", (message, now(), task_id))

    def state(self) -> dict[str, Any]:
        return {
            "endpoints": self.endpoints(),
            "projects": self.projects(),
            "sessions": self.sessions(),
            "tasks": self.tasks(),
        }

    def summary(self, profile: str = "default", task_limit: int = 10) -> dict[str, Any]:
        task_limit = max(1, min(task_limit, 30))
        tasks = self.tasks()[:task_limit]
        active = [task for task in tasks if task.get("status") in {"queued", "running", "pending"}]
        recent_done = [task for task in tasks if task.get("status") in {"completed", "error", "cancelled"}]
        return {
            "context": self.context(profile),
            "endpoints": self.endpoints(),
            "active_tasks": active,
            "recent_tasks": recent_done[:task_limit],
            "counts": {
                "active": len(active),
                "recent": len(recent_done),
                "sessions": self.session_count(),
            },
        }

    def endpoint(self, endpoint_id: str) -> dict[str, Any] | None:
        row = self.db.execute("select * from endpoints where endpoint_id=?", (endpoint_id,)).fetchone()
        return self.endpoint_row(row) if row else None

    def endpoints(self) -> list[dict[str, Any]]:
        return [self.endpoint_row(row) for row in self.db.execute("select * from endpoints order by endpoint_id")]

    def endpoint_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "endpoint_id": row["endpoint_id"],
            "label": row["label"],
            "status": row["status"],
            "capabilities": read_json(row["capabilities_json"], {}),
            "last_seen_at": row["last_seen_at"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def project(self, alias: str) -> dict[str, Any] | None:
        row = self.db.execute("select * from projects where alias=?", (alias,)).fetchone()
        return dict(row) if row else None

    def projects(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self.db.execute("select * from projects order by alias")]

    def sessions(self, endpoint_id: str | None = None, project_alias: str | None = None) -> list[dict[str, Any]]:
        params: list[Any] = []
        where: list[str] = []
        if endpoint_id:
            where.append("s.endpoint_id=?")
            params.append(endpoint_id)
        if project_alias:
            project = self.project(project_alias)
            if project:
                where.append("s.cwd=?")
                params.append(project["path"])
        sql = "select s.* from sessions s"
        if where:
            sql += " where " + " and ".join(where)
        sql += " order by s.updated_at desc, s.session_id asc"
        return [dict(row) for row in self.db.execute(sql, params)]

    def recent_project_session(self, project_alias: str) -> dict[str, Any] | None:
        sessions = self.sessions(project_alias=project_alias)
        return sessions[0] if sessions else None

    def task(self, task_id: str) -> dict[str, Any] | None:
        row = self.db.execute("select * from tasks where task_id=?", (task_id,)).fetchone()
        return dict(row) if row else None

    def tasks(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self.db.execute("select * from tasks order by created_at desc limit 50")]

    def chat_tasks(self, channel: str, chat_id: str, limit: int = 10) -> list[dict[str, Any]]:
        return [
            dict(row)
            for row in self.db.execute(
                "select * from tasks where chat_channel=? and chat_id=? order by created_at desc limit ?",
                (channel, chat_id, max(1, min(limit, 50))),
            )
        ]

    def chat_active_task(self, channel: str, chat_id: str) -> dict[str, Any] | None:
        row = self.db.execute(
            """
            select * from tasks
            where chat_channel=? and chat_id=? and status in ('queued','running','pending')
            order by updated_at desc limit 1
            """,
            (channel, chat_id),
        ).fetchone()
        return dict(row) if row else None

    def session_count(self) -> int:
        row = self.db.execute("select count(*) as n from sessions").fetchone()
        return int(row["n"]) if row else 0

    def events(self, task_or_session: str | None = None, tail: int = 20) -> list[dict[str, Any]]:
        if task_or_session:
            rows = self.db.execute(
                "select * from events where task_id=? or session_id=? order by event_id desc limit ?",
                (task_or_session, task_or_session, tail),
            ).fetchall()
        else:
            rows = self.db.execute("select * from events order by event_id desc limit ?", (tail,)).fetchall()
        return [self.event_row(row) for row in reversed(rows)]

    def chat_binding(self, channel: str, chat_id: str) -> dict[str, Any] | None:
        row = self.db.execute(
            "select * from chat_bindings where channel=? and chat_id=?",
            (channel, chat_id),
        ).fetchone()
        return dict(row) if row else None

    def chat_bindings(self, channel: str | None = None) -> list[dict[str, Any]]:
        if channel:
            rows = self.db.execute("select * from chat_bindings where channel=? order by updated_at desc", (channel,)).fetchall()
        else:
            rows = self.db.execute("select * from chat_bindings order by updated_at desc").fetchall()
        return [dict(row) for row in rows]

    def resolve_session_chat(self, channel: str, owner_chat_id: str, selector: str) -> dict[str, Any] | None:
        selector = (selector or "").strip()
        if not selector:
            return None
        mappings = self.session_chats(channel, owner_chat_id, 500)
        if selector.isdigit():
            index = int(selector)
            if 1 <= index <= len(mappings):
                return mappings[index - 1]
        exact = [item for item in mappings if item["binding"].get("session_id") == selector]
        if len(exact) == 1:
            return exact[0]
        prefix = [
            item for item in mappings
            if str(item["binding"].get("session_id") or "").startswith(selector)
            or selector.lower() in str(item["binding"].get("title") or "").lower()
        ]
        return prefix[0] if len(prefix) == 1 else None

    def project_alias_for_session(self, session: dict[str, Any]) -> str | None:
        cwd = session.get("cwd")
        if not cwd:
            return None
        for project in self.projects():
            if project.get("path") == cwd:
                return project.get("alias")
        return None

    @staticmethod
    def session_entry_chat_id(owner_chat_id: str, session_id: str) -> str:
        base = str(owner_chat_id or "").strip().rstrip(":")
        return f"{base}:session:{session_id}" if session_id else f"{base}:session:"

    @staticmethod
    def mapping_session_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "session_id": row["session_id"],
            "endpoint_id": row["endpoint_id"],
            "source": row["source"],
            "title": row["title"],
            "cwd": row["cwd"],
            "rollout_path": row["rollout_path"],
            "status": row["status"],
            "active_turn_id": row["active_turn_id"],
            "updated_at": row["session_updated_at"],
        }

    def event_row(self, row: sqlite3.Row) -> dict[str, Any]:
        data = read_json(row["data_json"], None)
        return {
            "event_id": row["event_id"],
            "endpoint_id": row["endpoint_id"],
            "task_id": row["task_id"],
            "session_id": row["session_id"],
            "type": row["type"],
            "message": row["message"],
            "data": data,
            "created_at": row["created_at"],
        }

    def command_row(self, row: sqlite3.Row, status: str | None = None) -> dict[str, Any]:
        return {
            "command_id": row["command_id"],
            "endpoint_id": row["endpoint_id"],
            "task_id": row["task_id"],
            "type": row["type"],
            "payload": read_json(row["payload_json"], {}),
            "status": status or row["status"],
            "created_at": row["created_at"],
        }

    def resolve_session(self, selector: str) -> dict[str, Any] | None:
        selector = (selector or "").strip()
        if not selector:
            return None
        exact = self.db.execute("select * from sessions where session_id=?", (selector,)).fetchone()
        if exact:
            return dict(exact)
        rows = self.db.execute(
            "select * from sessions where session_id like ? or title like ? order by updated_at desc",
            (selector + "%", "%" + selector + "%"),
        ).fetchall()
        return dict(rows[0]) if len(rows) == 1 else None

    def context(self, profile: str) -> dict[str, Any]:
        self.ensure_context(profile)
        row = self.db.execute("select * from context where profile=?", (profile,)).fetchone()
        return dict(row) if row else {"profile": profile}

    def ensure_context(self, profile: str) -> None:
        self.db.execute(
            "insert or ignore into context(profile,updated_at) values(?,?)",
            (profile, now()),
        )

    def first_online_endpoint(self) -> dict[str, Any] | None:
        row = self.db.execute("select * from endpoints where status='online' order by last_seen_at desc limit 1").fetchone()
        return self.endpoint_row(row) if row else None

    def notify(self, endpoint_id: str) -> None:
        q = self.listeners.get(endpoint_id)
        if q:
            try:
                q.put_nowait(None)
            except queue.Full:
                pass


class FleetHandler(BaseHTTPRequestHandler):
    server: "FleetHttpServer"

    def do_GET(self) -> None:
        self.route("GET")

    def do_POST(self) -> None:
        self.route("POST")

    def log_message(self, fmt: str, *args: Any) -> None:
        if self.server.quiet:
            return
        super().log_message(fmt, *args)

    def route(self, method: str) -> None:
        if not self.authorized():
            return json_response(self, HTTPStatus.UNAUTHORIZED, {"ok": False, "error": "unauthorized"})
        try:
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            qs = parse_qs(parsed.query)
            if method == "GET" and path in {"/healthz", "/readyz"}:
                return json_response(self, 200, {"ok": True})
            if method == "GET" and path == "/api/state":
                return json_response(self, 200, self.server.store.state())
            if method == "GET" and path == "/api/summary":
                return json_response(self, 200, self.server.store.summary(first(qs, "profile") or "default", int(first(qs, "limit") or "10")))
            if method == "GET" and path == "/api/endpoints":
                return json_response(self, 200, {"endpoints": self.server.store.endpoints()})
            if method == "GET" and path == "/api/projects":
                return json_response(self, 200, {"projects": self.server.store.projects()})
            if method == "GET" and path == "/api/sessions":
                return json_response(self, 200, {"sessions": self.server.store.sessions(first(qs, "endpoint"), first(qs, "project"))})
            if method == "GET" and path == "/api/tasks":
                return json_response(self, 200, {"tasks": self.server.store.tasks()})
            if method == "GET" and path == "/api/events":
                return json_response(self, 200, {"events": self.server.store.events(first(qs, "target"), int(first(qs, "tail") or "20"))})
            if method == "GET" and path == "/api/chat-bindings":
                channel = first(qs, "channel")
                chat_id = first(qs, "chat_id")
                if channel and chat_id:
                    return json_response(self, 200, self.server.store.chat_status(channel, chat_id))
                return json_response(self, 200, {"bindings": self.server.store.chat_bindings(channel)})
            if method == "GET" and path == "/api/session-chats":
                return json_response(self, 200, {"mappings": self.server.store.session_chats(
                    require_query(qs, "channel"),
                    require_query(qs, "owner_chat_id"),
                    int(first(qs, "limit") or "200"),
                )})
            if method == "GET" and path == "/api/worker/poll":
                endpoint_id = first(qs, "endpoint_id") or ""
                timeout = min(30.0, max(0.0, float(first(qs, "timeout") or "25")))
                return json_response(self, 200, {"commands": self.server.store.poll_commands(endpoint_id, timeout)})

            body = parse_json_body(self) if method == "POST" else {}
            if method == "POST" and path == "/api/worker/register":
                return json_response(self, 200, self.server.store.register_endpoint(
                    require(body, "endpoint_id"),
                    body.get("label") or require(body, "endpoint_id"),
                    body.get("capabilities") or {},
                    body.get("sessions") if isinstance(body.get("sessions"), list) else None,
                ))
            if method == "POST" and path == "/api/worker/heartbeat":
                return json_response(self, 200, self.server.store.heartbeat(
                    require(body, "endpoint_id"),
                    body.get("sessions") if isinstance(body.get("sessions"), list) else None,
                ))
            if method == "POST" and path == "/api/worker/events":
                return json_response(self, 200, self.server.store.record_worker_events(require(body, "endpoint_id"), body))
            if method == "POST" and path == "/api/projects":
                return json_response(self, 200, self.server.store.register_project(
                    require(body, "alias"),
                    require(body, "endpoint_id"),
                    require(body, "path"),
                    body.get("mode") or "vscode",
                ))
            if method == "POST" and path == "/api/context/project":
                return json_response(self, 200, self.server.store.use_project(body.get("profile") or "default", require(body, "project_alias")))
            if method == "POST" and path == "/api/context/session":
                return json_response(self, 200, self.server.store.use_session(body.get("profile") or "default", require(body, "session_selector")))
            if method == "POST" and path == "/api/context/clear":
                return json_response(self, 200, self.server.store.clear_context(body.get("profile") or "default"))
            if method == "POST" and path == "/api/chat-bindings":
                return json_response(self, 200, self.server.store.bind_chat(
                    require(body, "channel"),
                    require(body, "chat_id"),
                    body.get("profile") if isinstance(body.get("profile"), str) else None,
                    require(body, "project_alias"),
                    body.get("endpoint_id") if isinstance(body.get("endpoint_id"), str) else None,
                    body.get("session_policy") or "project-default",
                ))
            if method == "POST" and path == "/api/chat-bindings/clear":
                return json_response(self, 200, self.server.store.unbind_chat(require(body, "channel"), require(body, "chat_id")))
            if method == "POST" and path == "/api/chat-bindings/task":
                return json_response(self, 202, self.server.store.create_chat_task(
                    require(body, "channel"),
                    require(body, "chat_id"),
                    require(body, "prompt"),
                ))
            if method == "POST" and path == "/api/chat-bindings/stop":
                status = self.server.store.chat_status(require(body, "channel"), require(body, "chat_id"))
                active = status.get("active_task")
                if not active:
                    raise KeyError("no active task for chat")
                return json_response(self, 202, self.server.store.enqueue_stop(active["task_id"]))
            if method == "POST" and path == "/api/session-chats/sync":
                return json_response(self, 200, self.server.store.sync_session_chats(
                    require(body, "channel"),
                    require(body, "owner_chat_id"),
                    body.get("profile") if isinstance(body.get("profile"), str) else None,
                    body.get("endpoint_id") if isinstance(body.get("endpoint_id"), str) else None,
                    body.get("project_alias") if isinstance(body.get("project_alias"), str) else None,
                    int(body.get("limit") or 200),
                ))
            if method == "POST" and path == "/api/session-chats/bind":
                return json_response(self, 200, self.server.store.bind_session_chat(
                    require(body, "channel"),
                    require(body, "chat_id"),
                    body.get("profile") if isinstance(body.get("profile"), str) else None,
                    require(body, "session_selector"),
                    body.get("project_alias") if isinstance(body.get("project_alias"), str) else None,
                    body.get("session_policy") or "fixed-session",
                ))
            if method == "POST" and path == "/api/session-chats/task":
                return json_response(self, 202, self.server.store.create_session_chat_task(
                    require(body, "channel"),
                    require(body, "owner_chat_id"),
                    require(body, "selector"),
                    require(body, "prompt"),
                ))
            if method == "POST" and path == "/api/tasks":
                return json_response(self, 202, self.server.store.create_task(
                    body.get("profile") or "default",
                    require(body, "prompt"),
                    body.get("project_alias"),
                    body.get("session_selector"),
                    body.get("mode"),
                ))
            if method == "POST" and path.startswith("/api/tasks/") and path.endswith("/cancel"):
                task_id = path.split("/")[3]
                return json_response(self, 202, self.server.store.enqueue_stop(task_id))
            if method == "POST" and path == "/api/stop":
                return json_response(self, 202, self.server.store.enqueue_stop(require(body, "target")))
            if method == "GET" and path == "/api/context":
                return json_response(self, 200, self.server.store.context(first(qs, "profile") or "default"))
            return json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})
        except Exception as exc:
            return json_response(self, HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})

    def authorized(self) -> bool:
        token = self.server.token
        if not token:
            return True
        return self.headers.get("authorization") == f"Bearer {token}"


class FleetHttpServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], store: FleetStore, token: str | None, quiet: bool):
        super().__init__(server_address, FleetHandler)
        self.store = store
        self.token = token
        self.quiet = quiet


def first(qs: dict[str, list[str]], key: str) -> str | None:
    values = qs.get(key)
    return values[0] if values else None


def require_query(qs: dict[str, list[str]], key: str) -> str:
    return require_value(first(qs, key), key)


def require(body: dict[str, Any], key: str) -> str:
    value = body.get(key)
    return require_value(value, key)


def require_value(value: Any, key: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} is required")
    return value.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description="Codex fleet manager")
    parser.add_argument("--host", default=os.environ.get("CODEX_FLEET_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CODEX_FLEET_PORT", "18992")))
    parser.add_argument("--db", default=os.environ.get("CODEX_FLEET_DB", "/data/state/codex-fleet/fleet.db"))
    parser.add_argument("--token", default=os.environ.get("CODEX_FLEET_TOKEN"))
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    store = FleetStore(Path(args.db))
    server = FleetHttpServer((args.host, args.port), store, args.token, args.quiet)
    print(f"codex fleet manager listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
