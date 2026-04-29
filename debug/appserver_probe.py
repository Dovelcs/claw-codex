#!/usr/bin/env python3
"""Minimal Python probe for Codex app-server JSON-RPC notifications.

This intentionally avoids third-party websocket packages so it can run on the
company machine as-is. It supports the app-server unix socket transport used by
`codex app-server --listen unix://...`.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


DEFAULT_CODEX_BIN = "/home/donovan/.vscode-server/extensions/openai.chatgpt-26.422.71525-linux-x64/bin/linux-x86_64/codex"


class ResultWriter:
    def __init__(self, out_dir: Path, thread_id: str | None = None) -> None:
        self.out_dir = out_dir
        self.thread_id = thread_id
        self.delta_text = ""
        self.final_text = ""
        if out_dir.exists() and not out_dir.is_dir():
            raise RuntimeError(f"output path exists and is not a directory: {out_dir}")
        out_dir.mkdir(parents=True, exist_ok=True)

    def set_thread(self, thread_id: str) -> None:
        self.thread_id = thread_id

    def write_response(self, method: str, result: Any) -> None:
        record = {"ts": time.time(), "kind": "response", "method": method, "threadId": self.thread_id, "result": result}
        append_jsonl(self.out_dir / "responses.jsonl", record)

    def write_notification(self, message: dict[str, Any]) -> None:
        if not message_matches_thread(message, self.thread_id):
            return
        record = {"ts": time.time(), "kind": "notification", "message": message}
        append_jsonl(self.out_dir / "events.jsonl", record)
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        method = str(message.get("method") or "")
        if method == "item/agentMessage/delta":
            delta = params.get("delta")
            if isinstance(delta, str):
                self.delta_text += delta
                (self.out_dir / "agent_delta.txt").write_text(self.delta_text, encoding="utf-8")
        if method == "item/completed":
            item = params.get("item")
            if isinstance(item, dict) and item.get("type") == "agentMessage":
                text = item.get("text")
                if isinstance(text, str):
                    self.final_text = text
                    (self.out_dir / "final.txt").write_text(text, encoding="utf-8")

    def write_summary(self) -> None:
        summary = {
            "threadId": self.thread_id,
            "agentDeltaChars": len(self.delta_text),
            "finalText": self.final_text,
            "files": {
                "responses": str(self.out_dir / "responses.jsonl"),
                "events": str(self.out_dir / "events.jsonl"),
                "agentDelta": str(self.out_dir / "agent_delta.txt"),
                "final": str(self.out_dir / "final.txt"),
            },
        }
        (self.out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class UnixWebSocketJsonRpc:
    def __init__(self, socket_path: str, timeout: float = 30.0, writer: ResultWriter | None = None) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self.writer = writer
        self.sock: socket.socket | None = None
        self.next_id = 1
        self.pending: dict[int, Any] = {}
        self.lock = threading.Lock()
        self.reader: threading.Thread | None = None
        self.closed = threading.Event()

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock
        self._websocket_handshake()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def close(self) -> None:
        self.closed.set()
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass

    def request(self, method: str, params: Any | None = None) -> Any:
        with self.lock:
            request_id = self.next_id
            self.next_id += 1
            event = threading.Event()
            self.pending[request_id] = {"event": event, "response": None}
            payload: dict[str, Any] = {"id": request_id, "method": method}
            if params is not None:
                payload["params"] = params
            self._send_text(json.dumps(payload, ensure_ascii=False))

        if not event.wait(self.timeout):
            with self.lock:
                self.pending.pop(request_id, None)
            raise TimeoutError(f"request timed out: {method}")

        response = self.pending.pop(request_id)["response"]
        if "error" in response:
            raise RuntimeError(json.dumps(response["error"], ensure_ascii=False))
        return response.get("result")

    def _send_text(self, text: str) -> None:
        if self.sock is None:
            raise RuntimeError("not connected")
        self.sock.sendall(encode_client_frame(text.encode("utf-8")))

    def _websocket_handshake(self) -> None:
        if self.sock is None:
            raise RuntimeError("not connected")
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
        self.sock.sendall(request)
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            response += chunk
            if len(response) > 65536:
                break
        header = response.split(b"\r\n\r\n", 1)[0].decode("iso-8859-1", errors="replace")
        if " 101 " not in header.splitlines()[0]:
            raise RuntimeError(f"websocket upgrade failed: {header}")
        accept = ""
        for line in header.splitlines()[1:]:
            if line.lower().startswith("sec-websocket-accept:"):
                accept = line.split(":", 1)[1].strip()
                break
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()).decode("ascii")
        if accept and accept != expected:
            raise RuntimeError("websocket upgrade returned invalid Sec-WebSocket-Accept")

    def _read_loop(self) -> None:
        buffer = b""
        while not self.closed.is_set():
            try:
                chunk = self.sock.recv(65536) if self.sock is not None else b""
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while True:
                decoded = try_decode_server_frame(buffer)
                if decoded is None:
                    break
                opcode, payload, consumed = decoded
                buffer = buffer[consumed:]
                if opcode == 0x8:
                    self.closed.set()
                    return
                if opcode not in (0x1, 0x2):
                    continue
                self._handle_message(payload.decode("utf-8", errors="replace"))

    def _handle_message(self, text: str) -> None:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return

        if isinstance(message, dict) and "id" in message:
            request_id = message.get("id")
            with self.lock:
                pending = self.pending.get(request_id)
                if pending:
                    pending["response"] = message
                    pending["event"].set()
                    return

        if isinstance(message, dict):
            if self.writer is not None:
                self.writer.write_notification(message)
            if message_matches_thread(message, self.writer.thread_id if self.writer else None):
                print(json.dumps({"kind": "notification", "message": message}, ensure_ascii=False), flush=True)


def encode_client_frame(payload: bytes) -> bytes:
    mask = os.urandom(4)
    length = len(payload)
    if length < 126:
        header = bytes([0x81, 0x80 | length])
    elif length <= 0xFFFF:
        header = bytes([0x81, 0x80 | 126]) + struct.pack(">H", length)
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", length)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return header + mask + masked


def try_decode_server_frame(buffer: bytes) -> tuple[int, bytes, int] | None:
    if len(buffer) < 2:
        return None
    opcode = buffer[0] & 0x0F
    masked = bool(buffer[1] & 0x80)
    length = buffer[1] & 0x7F
    offset = 2
    if length == 126:
        if len(buffer) < offset + 2:
            return None
        length = struct.unpack(">H", buffer[offset : offset + 2])[0]
        offset += 2
    elif length == 127:
        if len(buffer) < offset + 8:
            return None
        length = struct.unpack(">Q", buffer[offset : offset + 8])[0]
        offset += 8
    mask = b""
    if masked:
        if len(buffer) < offset + 4:
            return None
        mask = buffer[offset : offset + 4]
        offset += 4
    if len(buffer) < offset + length:
        return None
    payload = buffer[offset : offset + length]
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload, offset + length


def wait_for_socket(path: Path, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                    sock.settimeout(0.5)
                    sock.connect(str(path))
                    return
            except OSError:
                pass
        time.sleep(0.1)
    raise TimeoutError(f"socket did not become ready: {path}")


def start_server(codex_bin: str, socket_path: Path, log_path: Path) -> subprocess.Popen[bytes]:
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    log = log_path.open("ab")
    proc = subprocess.Popen(
        [
            codex_bin,
            "app-server",
            "--analytics-default-enabled",
            "--listen",
            f"unix://{socket_path}",
        ],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    wait_for_socket(socket_path, 10.0)
    return proc


def normalize_thread_list(result: Any) -> list[dict[str, Any]]:
    if isinstance(result, list):
        return [item for item in result if isinstance(item, dict)]
    if isinstance(result, dict):
        for key in ("data", "threads"):
            value = result.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def message_matches_thread(message: dict[str, Any], thread_id: str | None) -> bool:
    if not thread_id:
        return True
    params = message.get("params")
    if not isinstance(params, dict):
        return False
    return params.get("threadId") == thread_id or params.get("thread_id") == thread_id


def current_thread_from_list(threads: list[dict[str, Any]], requested: str | None) -> str | None:
    if requested:
        return requested
    if threads:
        candidate = threads[0].get("id")
        if isinstance(candidate, str):
            return candidate
    return None


def filter_threads_for_current(threads: list[dict[str, Any]], thread_id: str | None) -> list[dict[str, Any]]:
    if not thread_id:
        return threads[:1]
    return [thread for thread in threads if thread.get("id") == thread_id]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=str(Path(tempfile.gettempdir()) / "codex-debug" / "app-server.sock"))
    parser.add_argument("--codex-bin", default=os.environ.get("CODEX_BIN") or DEFAULT_CODEX_BIN)
    parser.add_argument("--start-server", dest="start_server", action="store_true", default=True)
    parser.add_argument("--no-start-server", dest="start_server", action="store_false")
    parser.add_argument("--thread")
    parser.add_argument("--send")
    parser.add_argument("--listen-seconds", type=float, default=20.0)
    parser.add_argument("--log", default=str(Path(tempfile.gettempdir()) / "codex-debug" / "app-server.log"))
    parser.add_argument("--out-dir", default="test.txt", help="Directory used to save current-thread probe results.")
    args = parser.parse_args()

    proc: subprocess.Popen[bytes] | None = None
    socket_path = Path(args.socket)
    writer = ResultWriter(Path(args.out_dir), args.thread)
    if args.start_server:
        proc = start_server(args.codex_bin, socket_path, Path(args.log))
        print(json.dumps({"kind": "server_started", "pid": proc.pid, "socket": str(socket_path), "log": args.log}), flush=True)

    client = UnixWebSocketJsonRpc(str(socket_path), writer=writer)
    try:
        client.connect()
        init = client.request(
            "initialize",
            {
                "clientInfo": {"name": "codex-appserver-python-probe", "title": "Python Probe", "version": "0.1.0"},
                "capabilities": {"experimentalApi": True},
            },
        )
        threads = normalize_thread_list(
            client.request(
                "thread/list",
                {
                    "sourceKinds": ["vscode"],
                    "limit": 5,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "useStateDbOnly": True,
                },
            )
        )
        target_thread = current_thread_from_list(threads, args.thread)
        if target_thread:
            writer.set_thread(target_thread)
        filtered_threads = filter_threads_for_current(threads, target_thread)
        thread_list_record = {"thread_count": len(filtered_threads), "threads": filtered_threads}
        writer.write_response("thread/list", thread_list_record)
        print(json.dumps({"kind": "response", "method": "thread/list", **thread_list_record}, ensure_ascii=False), flush=True)
        if target_thread:
            resumed = client.request("thread/resume", {"threadId": target_thread, "excludeTurns": True})
            writer.write_response("thread/resume", resumed)
            print(json.dumps({"kind": "response", "method": "thread/resume", "result": resumed}, ensure_ascii=False), flush=True)
        if target_thread and args.send:
            started = client.request(
                "turn/start",
                {"threadId": target_thread, "input": [{"type": "text", "text": args.send, "text_elements": []}]},
            )
            writer.write_response("turn/start", started)
            print(json.dumps({"kind": "response", "method": "turn/start", "result": started}, ensure_ascii=False), flush=True)
        if args.listen_seconds > 0:
            time.sleep(args.listen_seconds)
        writer.write_summary()
        print(json.dumps({"kind": "saved", "out_dir": str(writer.out_dir), "threadId": writer.thread_id}, ensure_ascii=False), flush=True)
        return 0
    finally:
        client.close()
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
