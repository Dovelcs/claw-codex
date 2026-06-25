#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/mkb_find_live_test_session.sh [title]

Finds a fixed live Company Codex history session by title using read-only GET
requests against the MKB relay. It never sends, guides, interrupts, or posts
commands.

Environment:
  MKB_RELAY_URL       Relay base URL. Default: http://124.174.101.22:886
  MKB_SOURCE_ENDPOINT Endpoint to prefer. Default: quectel-lnx
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

title="${1:-Test}"
relay_url="${MKB_RELAY_URL:-http://124.174.101.22:886}"
preferred_endpoint="${MKB_SOURCE_ENDPOINT:-quectel-lnx}"

python3 - "$relay_url" "$preferred_endpoint" "$title" <<'PY'
import json
import shlex
import sys
import urllib.parse
import urllib.request

relay_url = sys.argv[1].rstrip("/")
preferred_endpoint = sys.argv[2]
target_title = sys.argv[3]

blocked_ids = {"linux-vscode-main", "codex-vscode-current", "session-default", "session-1"}


def get_json(path, params=None):
    url = relay_url + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=12) as response:
        return json.load(response)


def blocked(session):
    sid = session.get("session_id", "")
    return sid in blocked_ids or sid.startswith("fixture-")


try:
    health = get_json("/health")
    state = get_json("/v1/state")
except Exception as exc:
    print(f"error: failed to read relay state from {relay_url}: {exc}", file=sys.stderr)
    sys.exit(70)

if not health.get("ok"):
    print(f"error: relay health is not ok: {health}", file=sys.stderr)
    sys.exit(71)

sessions = []
for session in state.get("sessions", []):
    if blocked(session):
        continue
    if (session.get("title") or "").strip() != target_title:
        continue
    if session.get("endpoint_id") != preferred_endpoint:
        continue
    if session.get("source") != "codex-vscode":
        continue
    endpoint_id = session.get("endpoint_id") or preferred_endpoint
    session_id = session.get("session_id") or ""
    message_count = 0
    first_text = ""
    last_text = ""
    try:
        messages = get_json(
            "/v1/messages",
            {"endpoint_id": endpoint_id, "session_id": session_id, "after_seq": "0"},
        ).get("messages", [])
        message_count = len(messages)
        for message in messages:
            text = (
                message.get("text")
                or message.get("content")
                or message.get("delta")
                or message.get("message")
                or ""
            )
            text = " ".join(str(text).split())
            if text and not first_text:
                first_text = text[:72]
            if text:
                last_text = text[:72]
    except Exception as exc:
        last_text = f"message-read-error: {exc}"
    sessions.append((message_count, session.get("updated_at", ""), session, first_text, last_text))

sessions.sort(key=lambda item: (item[0] > 0, item[1]), reverse=True)

print(f"relay={relay_url}")
print(f"endpoint={preferred_endpoint}")
print(f"title={target_title}")
print(f"health=ok backend={health.get('backend')} workers={health.get('workers')}")
print(f"matches={len(sessions)}")

if not sessions:
    print("recommended_session_id=")
    sys.exit(2)

for index, (message_count, _, session, first_text, last_text) in enumerate(sessions, start=1):
    marker = "recommended" if index == 1 and message_count > 0 else "candidate"
    print(
        f"{index}. {marker} session_id={session.get('session_id')} "
        f"messages={message_count} status={session.get('status')} "
        f"updated_at={session.get('updated_at')} cwd={session.get('cwd') or ''}"
    )
    if first_text:
        print(f"   first={first_text}")
    if last_text:
        print(f"   last={last_text}")

best_count, _, best, _, best_last_text = sessions[0]
if best_count <= 0:
    print("recommended_session_id=")
    sys.exit(3)

best_id = best.get("session_id") or ""
best_title = best.get("title") or target_title
print(f"recommended_session_id={best_id}")
print(f"recommended_title={best_title}")
if best_last_text:
    print(f"recommended_expected_text={best_last_text}")
print("readonly_test_command="
      f"scripts/mkb_live_readonly_ui_test.sh {shlex.quote(best_id)} "
      f"{shlex.quote(best_title)} {shlex.quote(best_last_text)}")
PY
