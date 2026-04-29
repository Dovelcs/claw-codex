#!/usr/bin/env python3
"""Send one fixed message through the VS Code Codex IPC follower path.

This probe does not start `codex app-server`. It connects to the official
extensionHost IPC router and asks the current owner VS Code webview to start a
turn for the fixed conversation. If this path works, it should use the same
multi-window sync route as VS Code's own follower windows.
"""

from __future__ import annotations

import json
import os
import queue
import socket
import struct
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any


THREAD_ID = "019dd3d6-a736-7aa3-bd8c-d749124c5505"
PROMPT = "测试"
SOCKET_PATH = f"/tmp/codex-ipc/ipc-{os.getuid()}.sock"
OUT_DIR = Path(__file__).resolve().with_name("ipc-follower-probe")
REQUEST_TIMEOUT_SECONDS = 20.0
BROADCAST_COLLECT_SECONDS = 15.0

METHOD_VERSIONS = {
    "initialize": 0,
    "thread-follower-start-turn": 1,
}


class IpcClient:
    def __init__(self, sock: socket.socket, out_dir: Path) -> None:
        self.sock = sock
        self.out_dir = out_dir
        self.client_id = "initializing-client"
        self.responses: dict[str, dict[str, Any]] = {}
        self.broadcasts: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self.cv = threading.Condition()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.closed = False

    def start(self) -> None:
        self.reader.start()

    def request(self, method: str, params: Any, timeout: float = REQUEST_TIMEOUT_SECONDS, target_client_id: str | None = None) -> dict[str, Any]:
        request_id = str(uuid.uuid4())
        payload: dict[str, Any] = {
            "type": "request",
            "requestId": request_id,
            "sourceClientId": self.client_id,
            "version": METHOD_VERSIONS.get(method, 0),
            "method": method,
            "params": params,
        }
        if target_client_id is not None:
            payload["targetClientId"] = target_client_id
        self._send(payload)
        deadline = time.time() + timeout
        with self.cv:
            while request_id not in self.responses:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"IPC request timed out: {method}")
                self.cv.wait(remaining)
            response = self.responses.pop(request_id)
        append_jsonl(self.out_dir / "responses.jsonl", {"ts": time.time(), "method": method, "response": response})
        if method == "initialize" and response.get("resultType") == "success":
            result = response.get("result")
            if isinstance(result, dict) and isinstance(result.get("clientId"), str):
                self.client_id = result["clientId"]
        return response

    def _send(self, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        frame = struct.pack("<I", len(body)) + body
        append_jsonl(self.out_dir / "sent.jsonl", {"ts": time.time(), "payload": payload})
        self.sock.sendall(frame)

    def _read_loop(self) -> None:
        try:
            while True:
                message = self._read_message()
                if message is None:
                    return
                append_jsonl(self.out_dir / "messages.jsonl", {"ts": time.time(), "message": message})
                message_type = message.get("type")
                if message_type == "response" and isinstance(message.get("requestId"), str):
                    with self.cv:
                        self.responses[message["requestId"]] = message
                        self.cv.notify_all()
                elif message_type == "broadcast":
                    append_jsonl(self.out_dir / "broadcasts.jsonl", {"ts": time.time(), "message": message})
                    self.broadcasts.put(message)
                elif message_type == "client-discovery-request":
                    self._send(
                        {
                            "type": "client-discovery-response",
                            "requestId": message.get("requestId"),
                            "sourceClientId": self.client_id,
                            "targetClientId": message.get("sourceClientId"),
                            "method": message.get("method"),
                            "canHandle": False,
                        }
                    )
                elif message_type == "request":
                    self._send(
                        {
                            "type": "response",
                            "requestId": message.get("requestId"),
                            "method": message.get("method"),
                            "handledByClientId": self.client_id,
                            "resultType": "failure",
                            "error": {"message": "no-handler-for-request"},
                        }
                    )
        finally:
            self.closed = True
            with self.cv:
                self.cv.notify_all()

    def _read_message(self) -> dict[str, Any] | None:
        header = recv_exact(self.sock, 4)
        if header is None:
            return None
        (size,) = struct.unpack("<I", header)
        if size > 256 * 1024 * 1024:
            raise RuntimeError(f"oversized IPC frame: {size}")
        body = recv_exact(self.sock, size)
        if body is None:
            return None
        return json.loads(body.decode("utf-8"))


def main() -> int:
    if len(sys.argv) != 1:
        raise SystemExit("do not pass arguments; run: python3 debug/codex_ipc_follower_probe.py")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    clear_outputs()
    summary: dict[str, Any] = {
        "threadId": THREAD_ID,
        "prompt": PROMPT,
        "socketPath": SOCKET_PATH,
        "startedAt": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ok": False,
    }
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)
        client = IpcClient(sock, OUT_DIR)
        client.start()
        init = client.request("initialize", {"clientType": "vscode"})
        summary["initialize"] = init
        if init.get("resultType") != "success":
            raise RuntimeError(f"initialize failed: {init}")
        summary["clientId"] = client.client_id

        response = client.request(
            "thread-follower-start-turn",
            {
                "conversationId": THREAD_ID,
                "turnStartParams": {
                    "input": [{"type": "text", "text": PROMPT, "text_elements": []}],
                },
            },
        )
        summary["threadFollowerStartTurn"] = response
        summary["ok"] = response.get("resultType") == "success"
        collect_broadcasts(client, summary)
        print(json.dumps({"ok": summary["ok"], "response": response}, ensure_ascii=False), flush=True)
        return 0 if summary["ok"] else 2
    except Exception as error:
        summary["error"] = str(error)
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False), flush=True)
        return 1
    finally:
        summary["finishedAt"] = time.strftime("%Y-%m-%d %H:%M:%S")
        (OUT_DIR / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        try:
            sock.close()  # type: ignore[name-defined]
        except Exception:
            pass


def collect_broadcasts(client: IpcClient, summary: dict[str, Any]) -> None:
    deadline = time.time() + BROADCAST_COLLECT_SECONDS
    matched: list[dict[str, Any]] = []
    while time.time() < deadline:
        try:
            message = client.broadcasts.get(timeout=0.5)
        except queue.Empty:
            continue
        method = message.get("method")
        params = message.get("params")
        if method == "thread-stream-state-changed" and isinstance(params, dict) and params.get("conversationId") == THREAD_ID:
            matched.append(message)
    summary["matchedThreadStreamBroadcastCount"] = len(matched)
    if matched:
        summary["lastThreadStreamBroadcast"] = summarize_stream_broadcast(matched[-1])


def summarize_stream_broadcast(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params") if isinstance(message.get("params"), dict) else {}
    change = params.get("change") if isinstance(params.get("change"), dict) else {}
    summary: dict[str, Any] = {
        "sourceClientId": message.get("sourceClientId"),
        "changeType": change.get("type"),
    }
    if change.get("type") == "patches":
        patches = change.get("patches")
        if isinstance(patches, list):
            summary["patchCount"] = len(patches)
            summary["patchPaths"] = [patch.get("path") for patch in patches[:20] if isinstance(patch, dict)]
    elif change.get("type") == "snapshot":
        state = change.get("conversationState") if isinstance(change.get("conversationState"), dict) else {}
        summary["turnCount"] = len(state.get("turns") or []) if isinstance(state.get("turns"), list) else None
        summary["resumeState"] = state.get("resumeState")
        summary["title"] = state.get("title")
    return summary


def recv_exact(sock: socket.socket, size: int) -> bytes | None:
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def clear_outputs() -> None:
    for name in ("sent.jsonl", "responses.jsonl", "messages.jsonl", "broadcasts.jsonl", "summary.json"):
        try:
            (OUT_DIR / name).unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
