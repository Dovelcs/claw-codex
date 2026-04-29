#!/usr/bin/env python3
"""Send one fixed test message to Codex app-server over stdio.

This mimics the VS Code extension's app-server client shape: spawn
`codex app-server` with the default stdio transport, speak one JSON-RPC object
per line, resume a fixed VS Code thread, then send `测试`.

The point of this probe is to behave like a second VS Code window against the
same thread. It refuses to start if the target thread is not idle and waits for
the exact returned turn to complete or abort before exiting.
"""

from __future__ import annotations

import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


THREAD_ID = "019dd3d6-a736-7aa3-bd8c-d749124c5505"
PROMPT = "测试"
CODEX_BIN = "/home/donovan/.vscode-server/extensions/openai.chatgpt-26.422.71525-linux-x64/bin/linux-x86_64/codex"
OUT_DIR = Path(__file__).resolve().with_name("stdio-turn-probe")
REQUEST_TIMEOUT_SECONDS = 20.0
TURN_TIMEOUT_SECONDS = 15 * 60.0
NOTIFICATION_POLL_SECONDS = 0.5


class StdioAppServerClient:
    def __init__(self, proc: subprocess.Popen[bytes], out_dir: Path) -> None:
        self.proc = proc
        self.out_dir = out_dir
        self.next_id = 1
        self.responses: dict[int, dict[str, Any]] = {}
        self.notifications: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self.cv = threading.Condition()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)

    def start(self) -> None:
        self.reader.start()

    def request(self, method: str, params: Any | None = None, timeout: float = REQUEST_TIMEOUT_SECONDS) -> Any:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)
        deadline = time.time() + timeout
        with self.cv:
            while request_id not in self.responses:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"request timed out: {method}")
                self.cv.wait(remaining)
            response = self.responses.pop(request_id)
        append_jsonl(self.out_dir / "responses.jsonl", {"ts": time.time(), "method": method, "response": response})
        if "error" in response:
            raise RuntimeError(json.dumps(response["error"], ensure_ascii=False))
        return response.get("result")

    def notify(self, method: str, params: Any | None = None) -> None:
        payload: dict[str, Any] = {"method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)

    def _send(self, payload: dict[str, Any]) -> None:
        if self.proc.stdin is None:
            raise RuntimeError("app-server stdin is closed")
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        append_jsonl(self.out_dir / "sent.jsonl", {"ts": time.time(), "payload": payload})
        self.proc.stdin.write(body)
        self.proc.stdin.flush()

    def _read_loop(self) -> None:
        stream = self.proc.stdout
        if stream is None:
            return
        while True:
            message = read_jsonl_message(stream)
            if message is None:
                return
            append_jsonl(self.out_dir / "messages.jsonl", {"ts": time.time(), "message": message})
            if "id" in message:
                with self.cv:
                    self.responses[message["id"]] = message
                    self.cv.notify_all()
            else:
                append_jsonl(self.out_dir / "notifications.jsonl", {"ts": time.time(), "message": message})
                self.notifications.put(message)


def main() -> int:
    if len(sys.argv) != 1:
        raise SystemExit("do not pass arguments; run: python3 debug/codex_stdio_turn_probe.py")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    clear_outputs()
    proc = subprocess.Popen(
        [CODEX_BIN, "app-server", "--analytics-default-enabled"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    stderr_thread = threading.Thread(target=capture_stderr, args=(proc,), daemon=True)
    stderr_thread.start()
    client = StdioAppServerClient(proc, OUT_DIR)
    client.start()

    summary: dict[str, Any] = {
        "threadId": THREAD_ID,
        "prompt": PROMPT,
        "codexBin": CODEX_BIN,
        "startedAt": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ok": False,
    }
    try:
        init = client.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "codex-stdio-turn-probe",
                    "title": "Codex stdio turn probe",
                    "version": "0.1.0",
                },
                "capabilities": {"experimentalApi": True},
            },
        )
        summary["initialize"] = init
        client.notify("initialized", {})
        resume = client.request("thread/resume", {"threadId": THREAD_ID, "excludeTurns": True})
        summary["threadResume"] = resume
        status = extract_thread_status(resume)
        summary["initialThreadStatus"] = status
        if status != "idle":
            raise RuntimeError(f"target thread is not idle: {status!r}")
        started = client.request(
            "turn/start",
            {
                "threadId": THREAD_ID,
                "input": [{"type": "text", "text": PROMPT, "text_elements": []}],
            },
        )
        summary["turnStart"] = started
        summary["turnId"] = extract_turn_id(started)
        if not summary["turnId"]:
            raise RuntimeError("turn/start did not return a turn id")
        summary["ok"] = True
        print(json.dumps({"ok": True, "threadId": THREAD_ID, "turnStart": started}, ensure_ascii=False), flush=True)
        collect_notifications(client, summary)
        return 0 if summary.get("completed") else 2
    except Exception as error:
        summary["error"] = str(error)
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False), flush=True)
        return 1
    finally:
        summary["finishedAt"] = time.strftime("%Y-%m-%d %H:%M:%S")
        (OUT_DIR / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        stop_proc(proc)


def collect_notifications(client: StdioAppServerClient, summary: dict[str, Any]) -> None:
    turn_id = summary.get("turnId")
    if not isinstance(turn_id, str):
        raise RuntimeError("missing turn id before collecting notifications")

    deadline = time.time() + TURN_TIMEOUT_SECONDS
    final_text = ""
    completed = False
    aborted = False
    terminal_method: str | None = None
    while time.time() < deadline:
        try:
            message = client.notifications.get(timeout=NOTIFICATION_POLL_SECONDS)
        except queue.Empty:
            if client.proc.poll() is not None:
                break
            continue
        method = str(message.get("method") or "")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if not message_matches_turn(params, turn_id):
            continue
        if method == "item/agentMessage/delta":
            delta = params.get("delta")
            if isinstance(delta, str):
                final_text += delta
                (OUT_DIR / "agent_delta.txt").write_text(final_text, encoding="utf-8")
        elif method == "item/completed":
            item = params.get("item")
            if isinstance(item, dict) and item.get("type") in {"agentMessage", "message"}:
                text = item.get("text")
                if isinstance(text, str):
                    final_text = text
                    (OUT_DIR / "final.txt").write_text(text, encoding="utf-8")
        elif method == "turn/completed":
            completed = True
            terminal_method = method
            break
        elif method == "turn/aborted":
            aborted = True
            terminal_method = method
            break

    if not completed and not aborted:
        summary["timeout"] = True
        try:
            summary["interrupt"] = client.request("turn/interrupt", {"threadId": THREAD_ID, "turnId": turn_id})
        except Exception as error:
            summary["interruptError"] = str(error)

    summary["completed"] = completed
    summary["aborted"] = aborted
    summary["terminalMethod"] = terminal_method
    summary["finalText"] = final_text


def message_matches_turn(params: dict[str, Any], turn_id: str) -> bool:
    if params.get("threadId") != THREAD_ID and params.get("thread_id") != THREAD_ID:
        return False
    candidate = params.get("turnId") or params.get("turn_id")
    if isinstance(candidate, str):
        return candidate == turn_id
    return extract_turn_id(params) == turn_id


def extract_turn_id(value: Any) -> str | None:
    if isinstance(value, dict):
        for key in ("turnId", "turn_id", "id"):
            candidate = value.get(key)
            if isinstance(candidate, str):
                return candidate
        return extract_turn_id(value.get("turn"))
    return None


def extract_thread_status(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    thread = value.get("thread")
    if isinstance(thread, dict):
        status = thread.get("status")
        if isinstance(status, dict):
            status_type = status.get("type")
            if isinstance(status_type, str):
                return status_type
        if isinstance(status, str):
            return status
    status = value.get("status")
    if isinstance(status, dict):
        status_type = status.get("type")
        if isinstance(status_type, str):
            return status_type
    if isinstance(status, str):
        return status
    return None


def read_jsonl_message(stream: Any) -> dict[str, Any] | None:
    line = stream.readline()
    if not line:
        return None
    if len(line) > 16 * 1024 * 1024:
        raise RuntimeError("oversized app-server JSONL message")
    return json.loads(line.decode("utf-8"))


def capture_stderr(proc: subprocess.Popen[bytes]) -> None:
    if proc.stderr is None:
        return
    with (OUT_DIR / "stderr.log").open("ab") as handle:
        while True:
            chunk = proc.stderr.read(4096)
            if not chunk:
                return
            handle.write(chunk)
            handle.flush()


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def clear_outputs() -> None:
    for name in ("sent.jsonl", "responses.jsonl", "messages.jsonl", "notifications.jsonl", "summary.json", "agent_delta.txt", "final.txt", "stderr.log"):
        try:
            (OUT_DIR / name).unlink()
        except FileNotFoundError:
            pass


def stop_proc(proc: subprocess.Popen[bytes]) -> None:
    if proc.stdin is not None:
        try:
            proc.stdin.close()
        except OSError:
            pass
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
