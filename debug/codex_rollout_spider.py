#!/usr/bin/env python3
"""Tail Codex rollout JSONL files as a side-channel message feed.

This does not connect to, wrap, or modify the VS Code Codex app-server. It
observes the persistent files that VS Code Codex already writes under
~/.codex/sessions and normalizes user/assistant messages to JSONL.
"""

from __future__ import annotations

import json
import re
import signal
import sys
import time
from pathlib import Path
from typing import Any, Iterable

THREAD_ID = "019dd3d6-a736-7aa3-bd8c-d749124c5505"
ROLLOUT_PATH = Path("/home/donovan/.codex/sessions/2026/04/28/rollout-2026-04-28T19-25-53-019dd3d6-a736-7aa3-bd8c-d749124c5505.jsonl")
OUT_JSONL = Path(__file__).resolve().with_name("vscode-capture.jsonl")
OUT_TEXT = Path(__file__).resolve().with_name("vscode-capture.txt")
POLL_SECONDS = 0.25
SCHEMA = "codex_rollout_spider.v1"


def main() -> int:
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    if len(sys.argv) != 1:
        raise SystemExit("do not pass arguments; run: python3 codex_rollout_spider.py")

    if not ROLLOUT_PATH.exists():
        raise SystemExit(f"fixed rollout path not found: {ROLLOUT_PATH}")

    OUT_JSONL.parent.mkdir(parents=True, exist_ok=True)
    OUT_TEXT.parent.mkdir(parents=True, exist_ok=True)
    with OUT_JSONL.open("a", encoding="utf-8") as jsonl_handle, OUT_TEXT.open("a", encoding="utf-8") as text_handle:
        return tail_rollout(
            rollout_path=ROLLOUT_PATH,
            thread_id=THREAD_ID,
            from_start=False,
            listen_seconds=-1,
            poll=POLL_SECONDS,
            include_system=False,
            raw=False,
            output_handle=jsonl_handle,
            human_handle=text_handle,
        )


def tail_rollout(
    *,
    rollout_path: Path,
    thread_id: str,
    from_start: bool,
    listen_seconds: float,
    poll: float,
    include_system: bool,
    raw: bool,
    output_handle: Any,
    human_handle: Any | None = None,
) -> int:
    deadline = None if listen_seconds < 0 else time.time() + listen_seconds
    offset = 0 if from_start else file_size(rollout_path)
    buffer = ""
    dedupe = DedupeCache()

    emit(meta_event({
        "kind": "capture_started",
        "threadId": thread_id,
        "path": str(rollout_path),
        "offset": offset,
        "mode": "raw" if raw else "messages",
    }), output_handle, human_handle)

    while True:
        if rollout_path.exists():
            size = file_size(rollout_path)
            if size < offset:
                offset = 0
                buffer = ""
            with rollout_path.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(offset)
                chunk = handle.read()
                offset = handle.tell()
            if chunk:
                buffer += chunk
                lines = buffer.splitlines(keepends=True)
                buffer = ""
                if lines and not lines[-1].endswith("\n"):
                    buffer = lines.pop()
                for line in lines:
                    process_line(line, thread_id, raw, include_system, output_handle, human_handle, dedupe)

        if deadline is not None and time.time() >= deadline:
            break
        if listen_seconds == 0:
            break
        time.sleep(max(poll, 0.05))

    emit(meta_event({
        "kind": "capture_stopped",
        "threadId": thread_id,
        "path": str(rollout_path),
        "offset": offset,
    }), output_handle, human_handle)
    return 0


def process_line(line: str, thread_id: str, raw: bool, include_system: bool, output_handle: Any, human_handle: Any | None, dedupe: "DedupeCache") -> None:
    text = line.strip()
    if not text:
        return
    try:
        record = json.loads(text)
    except json.JSONDecodeError as error:
        emit(meta_event({"kind": "decode_error", "threadId": thread_id, "error": str(error), "line": text[:500]}), output_handle, human_handle)
        return

    if raw:
        emit(meta_event({"kind": "raw", "threadId": thread_id, "record": record}), output_handle, human_handle)
        return

    for message in normalize_record(record, thread_id, include_system):
        if not dedupe.remember(message):
            continue
        emit(message, output_handle, human_handle)


def normalize_record(record: dict[str, Any], thread_id: str, include_system: bool) -> Iterable[dict[str, Any]]:
    timestamp = record.get("timestamp")
    record_type = record.get("type")
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return []

    if record_type == "session_meta":
        meta = payload
        return [event_record({
            "kind": "session",
            "timestamp": timestamp,
            "threadId": meta.get("id") or thread_id,
            "source": meta.get("source"),
            "cwd": meta.get("cwd"),
            "cliVersion": meta.get("cli_version"),
        })]

    if record_type == "event_msg":
        payload_type = payload.get("type")
        if payload_type == "user_message":
            return [message_record(timestamp, thread_id, "user", payload.get("message"), "event_msg", payload.get("phase"))]
        if payload_type == "agent_message":
            return [message_record(timestamp, thread_id, "assistant", payload.get("message"), "event_msg", payload.get("phase"))]
        if payload_type == "task_started":
            return [event_record({
                "kind": "task_started",
                "timestamp": timestamp,
                "threadId": thread_id,
                "turnId": payload.get("turn_id"),
            })]
        if payload_type == "task_complete":
            return [event_record({
                "kind": "task_complete",
                "timestamp": timestamp,
                "threadId": thread_id,
                "turnId": payload.get("turn_id"),
            })]
        if payload_type == "context_compacted":
            return [message_record(timestamp, thread_id, "assistant", "上下文已压缩，继续处理...", "event_msg", "status")]
        return []

    if record_type == "response_item" and payload.get("type") == "message":
        role = payload.get("role")
        if role not in {"user", "assistant"} and not include_system:
            return []
        return [message_record(timestamp, thread_id, role, content_text(payload.get("content")), "response_item", payload.get("phase"))]

    return []


def message_record(timestamp: str | None, thread_id: str, role: Any, text: Any, source: str, phase: Any) -> dict[str, Any]:
    body = text if isinstance(text, str) else ""
    kind = message_kind(role, phase)
    return event_record({
        "kind": kind,
        "timestamp": timestamp,
        "threadId": thread_id,
        "role": role,
        "phase": phase,
        "source": source,
        "text": body,
    })


def message_kind(role: Any, phase: Any) -> str:
    if role == "user":
        return "user_input"
    if role == "assistant" and phase == "status":
        return "codex_status"
    if role == "assistant" and phase == "final_answer":
        return "final_answer"
    if role == "assistant":
        return "codex_reply"
    return "message"


def content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        for key in ("text", "input_text", "output_text"):
            value = item.get(key)
            if isinstance(value, str):
                parts.append(value)
                break
    return "\n".join(parts)


def emit(record: dict[str, Any], output_handle: Any, human_handle: Any | None = None) -> None:
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
    if output_handle:
        output_handle.write(line + "\n")
        output_handle.flush()
    human = human_line(record)
    print(human if human else line, flush=True)
    if human_handle:
        if human:
            human_handle.write(human + "\n")
            human_handle.flush()


def event_record(record: dict[str, Any]) -> dict[str, Any]:
    return {"schema": SCHEMA, **record}


def meta_event(record: dict[str, Any]) -> dict[str, Any]:
    return event_record(record)


class DedupeCache:
    def __init__(self, limit: int = 2048) -> None:
        self.limit = limit
        self.keys: list[tuple[Any, ...]] = []
        self.seen: set[tuple[Any, ...]] = set()

    def remember(self, record: dict[str, Any]) -> bool:
        key = self.key(record)
        if key in self.seen:
            return False
        self.seen.add(key)
        self.keys.append(key)
        if len(self.keys) > self.limit:
            old = self.keys.pop(0)
            self.seen.discard(old)
        return True

    @staticmethod
    def key(record: dict[str, Any]) -> tuple[Any, ...]:
        kind = record.get("kind")
        if kind in {"user_input", "codex_reply", "codex_status", "final_answer"}:
            return (
                kind,
                timestamp_bucket(record.get("timestamp")),
                record.get("threadId"),
                record.get("role"),
                record.get("phase"),
                record.get("text"),
            )
        if kind in {"task_started", "task_complete"}:
            return (kind, record.get("threadId"), record.get("turnId"), record.get("timestamp"))
        return (kind, record.get("threadId"), record.get("timestamp"), json.dumps(record, ensure_ascii=False, sort_keys=True))


def timestamp_bucket(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    # response_item and event_msg duplicates are usually written a few ms apart.
    return value[:19]


def human_line(record: dict[str, Any]) -> str:
    kind = record.get("kind")
    timestamp = format_timestamp(record.get("timestamp"))
    if kind == "capture_started":
        return f"\n[{timestamp}] CAPTURE START thread={short_id(record.get('threadId'))} offset={record.get('offset')}"
    if kind == "capture_stopped":
        return f"[{timestamp}] CAPTURE STOP offset={record.get('offset')}\n"
    if kind == "session":
        cwd = record.get("cwd") or ""
        return f"[{timestamp}] SESSION thread={short_id(record.get('threadId'))} source={record.get('source') or ''} cwd={cwd}"
    if kind == "task_started":
        return f"\n[{timestamp}] TASK START turn={short_id(record.get('turnId'))}"
    if kind == "task_complete":
        return f"[{timestamp}] TASK COMPLETE turn={short_id(record.get('turnId'))}\n"
    if kind == "user_input":
        return human_block(timestamp, "USER", clean_user_text(record.get("text")))
    if kind == "codex_reply":
        return human_block(timestamp, "CODEX", clean_text(record.get("text")))
    if kind == "codex_status":
        return human_block(timestamp, "STATUS", clean_text(record.get("text")))
    if kind == "final_answer":
        return human_block(timestamp, "FINAL", clean_text(record.get("text")))
    if kind == "decode_error":
        return f"[{timestamp}] DECODE ERROR {record.get('error')}"
    return ""


def human_block(timestamp: str, label: str, text: str) -> str:
    if not text:
        return f"[{timestamp}] {label}: <empty>"
    return f"[{timestamp}] {label}:\n{indent(text)}"


def clean_user_text(value: Any) -> str:
    text = clean_text(value)
    marker = "## My request for Codex:"
    if marker in text:
        text = text.split(marker, 1)[1]
    text = re.sub(r"^# Context from my IDE setup:\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"^## Active file:.*?(?=^## |\Z)", "", text, flags=re.MULTILINE | re.DOTALL)
    text = re.sub(r"^## Open tabs:.*?(?=^## |\Z)", "", text, flags=re.MULTILINE | re.DOTALL)
    return clean_text(text)


def clean_text(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    text = value.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def indent(text: str) -> str:
    return "\n".join(f"  {line}" if line else "" for line in text.splitlines())


def format_timestamp(value: Any) -> str:
    if isinstance(value, str) and value:
        return value.replace("T", " ").replace("Z", "")
    return time.strftime("%Y-%m-%d %H:%M:%S")


def short_id(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return value[:13]


def file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
