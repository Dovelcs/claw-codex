#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: repair-vscode-codex-thread.sh [--restart-app-server] <thread-id>

Repairs a VS Code Codex history thread that exists in ~/.codex but will not open
because the root thread row is marked has_user_event=0.

Environment:
  CODEX_HOME  Codex state directory. Defaults to $HOME/.codex.
EOF
}

restart_app_server=0
thread_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart-app-server)
      restart_app_server=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'unknown option: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$thread_id" ]]; then
        printf 'unexpected extra argument: %s\n' "$1" >&2
        usage
        exit 2
      fi
      thread_id="$1"
      shift
      ;;
  esac
done

if [[ -z "$thread_id" ]]; then
  usage
  exit 2
fi

if [[ ! "$thread_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  printf 'invalid thread id: %s\n' "$thread_id" >&2
  exit 2
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

need_cmd sqlite3
need_cmd python3

codex_home="${CODEX_HOME:-$HOME/.codex}"
state_db="$codex_home/state_5.sqlite"
session_index="$codex_home/session_index.jsonl"

if [[ ! -f "$state_db" ]]; then
  printf 'missing state database: %s\n' "$state_db" >&2
  exit 1
fi
if [[ ! -f "$session_index" ]]; then
  printf 'missing session index: %s\n' "$session_index" >&2
  exit 1
fi

row="$(sqlite3 -separator $'\t' "$state_db" \
  "select rollout_path, title, has_user_event from threads where id='$thread_id';")"

if [[ -z "$row" ]]; then
  printf 'thread not found in %s: %s\n' "$state_db" "$thread_id" >&2
  exit 1
fi

IFS=$'\t' read -r rollout_path thread_title has_user_event <<<"$row"

if [[ ! -f "$rollout_path" ]]; then
  printf 'rollout file missing for %s: %s\n' "$thread_id" "$rollout_path" >&2
  exit 1
fi

python3 - "$rollout_path" "$thread_id" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
thread_id = sys.argv[2]
has_session_meta = False
has_user = False

with path.open("rb") as fh:
    for lineno, raw in enumerate(fh, 1):
        if b"\x00" in raw:
            raise SystemExit(f"NUL byte in rollout file at line {lineno}")
        try:
            obj = json.loads(raw)
        except Exception as exc:
            raise SystemExit(f"JSON parse error at line {lineno}: {exc}")

        payload = obj.get("payload") or {}
        if obj.get("type") == "session_meta":
            has_session_meta = payload.get("id") == thread_id

        if obj.get("type") == "event_msg" and payload.get("type") == "user_message":
            has_user = True

        if obj.get("type") == "response_item":
            if payload.get("type") == "message" and payload.get("role") == "user":
                has_user = True

if not has_session_meta:
    raise SystemExit(f"session_meta id does not match {thread_id}")
if not has_user:
    raise SystemExit("rollout parsed, but no user message was found")
PY

ts="$(date +%Y%m%d%H%M%S)"
db_backup="$state_db.bak-vscode-thread-$thread_id-$ts"
index_backup="$session_index.bak-vscode-thread-$thread_id-$ts"

sqlite3 "$state_db" ".backup '$db_backup'"
cp -a "$session_index" "$index_backup"

sqlite3 "$state_db" "update threads set has_user_event=1 where id='$thread_id';"

updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$session_index" "$thread_id" "$thread_title" "$updated_at" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
entry = {
    "id": sys.argv[2],
    "thread_name": sys.argv[3],
    "updated_at": sys.argv[4],
}
with path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")
PY

sqlite3 "$state_db" "pragma integrity_check;"
sqlite3 -separator $'\t' "$state_db" \
  "select id, title, has_user_event, updated_at from threads where id='$thread_id';"

printf 'rollout checked: %s\n' "$rollout_path"
printf 'state backup: %s\n' "$db_backup"
printf 'index backup: %s\n' "$index_backup"
printf 'index appended updated_at: %s\n' "$updated_at"

if [[ "$restart_app_server" == "1" ]]; then
  pkill -TERM -f '/openai.chatgpt-.*/bin/linux-x86_64/codex app-server' || true
  printf 'requested VS Code Codex app-server restart; reopen the Codex panel or reload the VS Code window.\n'
fi

if [[ "$has_user_event" == "1" ]]; then
  printf 'note: thread already had has_user_event=1 before repair; index was still refreshed.\n'
fi
