#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  MKB_LIVE_CODEX_SESSION_ID=<real-history-session-id> \
  MKB_CONFIRM_LIVE_CODEX_FULL_TEST=YES_SEND_TO_FIXED_HISTORY_SESSION \
  [MKB_LIVE_CODEX_SESSION_TITLE=Test] scripts/mkb_live_full_ui_test.sh

  scripts/mkb_live_full_ui_test.sh <real-history-session-id> [session-title] --confirm-send
  scripts/mkb_live_full_ui_test.sh <real-history-session-id> [session-title] --dry-run

Runs the mutating live Company Codex UI test:
  MKBUITests/testCodexSendGuideAndInterrupt

This test sends messages, guides an active turn, and interrupts it. It must only
target a fixed real history session, never the current bridge/work session.

--dry-run performs the same read-only preflight and prints the target without
launching the UI test or writing live gate files.
EOF
}

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

session_id="${MKB_LIVE_CODEX_SESSION_ID:-${1:-}}"
session_title="${MKB_LIVE_CODEX_SESSION_TITLE:-Test}"
confirm="${MKB_CONFIRM_LIVE_CODEX_FULL_TEST:-}"
dry_run=0
if [[ "${2:-}" == "--confirm-send" ]]; then
  confirm="YES_SEND_TO_FIXED_HISTORY_SESSION"
elif [[ "${2:-}" == "--dry-run" ]]; then
  dry_run=1
elif [[ -n "${2:-}" ]]; then
  session_title="$2"
fi
if [[ "${3:-}" == "--confirm-send" ]]; then
  confirm="YES_SEND_TO_FIXED_HISTORY_SESSION"
elif [[ "${3:-}" == "--dry-run" ]]; then
  dry_run=1
fi

destination="${MKB_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
relay_url="${MKB_RELAY_URL:-http://124.174.101.22:886}"
preferred_endpoint="${MKB_SOURCE_ENDPOINT:-quectel-lnx}"
stamp="$(date +%Y%m%d-%H%M%S)"
result_bundle="${MKB_RESULT_BUNDLE_PATH:-/tmp/MKB-live-full-${stamp}.xcresult}"
log_path="${MKB_LIVE_FULL_LOG:-${result_bundle%.xcresult}.log}"

if [[ -z "$session_id" ]]; then
  usage
  echo "error: MKB_LIVE_CODEX_SESSION_ID is required." >&2
  exit 64
fi

case "$session_id" in
  linux-vscode-main|codex-vscode-current)
    echo "error: refusing current bridge session '$session_id'; pass a real fixed history session." >&2
    exit 65
    ;;
  fixture-*|fixture)
    echo "error: refusing fixture session '$session_id'; this entry is for live Company Codex verification." >&2
    exit 66
    ;;
esac

python3 - "$relay_url" "$preferred_endpoint" "$session_id" "$session_title" <<'PY'
import json
import sys
import urllib.parse
import urllib.request

relay_url, preferred_endpoint, session_id, expected_title = sys.argv[1:5]
relay_url = relay_url.rstrip("/")
blocked_ids = {"linux-vscode-main", "codex-vscode-current", "session-default", "session-1"}


def get_json(path, params=None):
    url = relay_url + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=12) as response:
        return json.load(response)


try:
    health = get_json("/health")
    state = get_json("/v1/state")
except Exception as exc:
    print(f"error: live preflight failed to read relay state from {relay_url}: {exc}", file=sys.stderr)
    sys.exit(70)

if not health.get("ok"):
    print(f"error: live preflight relay health is not ok: {health}", file=sys.stderr)
    sys.exit(71)

session = next((item for item in state.get("sessions", []) if item.get("session_id") == session_id), None)
if session is None:
    print(f"error: live preflight could not find session_id={session_id}", file=sys.stderr)
    sys.exit(72)

if session_id in blocked_ids or session_id.startswith("fixture-"):
    print(f"error: live preflight refusing unsafe session_id={session_id}", file=sys.stderr)
    sys.exit(73)

endpoint_id = session.get("endpoint_id") or ""
source = session.get("source") or ""
title = (session.get("title") or "").strip()
status = (session.get("status") or "").strip()
active_turn_id = (session.get("active_turn_id") or "").strip()

if endpoint_id != preferred_endpoint:
    print(f"error: live preflight expected endpoint {preferred_endpoint}, got {endpoint_id}", file=sys.stderr)
    sys.exit(74)
if source != "codex-vscode":
    print(f"error: live preflight expected source codex-vscode, got {source}", file=sys.stderr)
    sys.exit(75)
if expected_title.strip() and title != expected_title.strip():
    print(f"error: live preflight expected title {expected_title!r}, got {title!r}", file=sys.stderr)
    sys.exit(76)
if status in {"running", "queued", "streaming"} or active_turn_id:
    print(f"error: live preflight refusing busy session status={status} active_turn_id={active_turn_id}", file=sys.stderr)
    sys.exit(77)

try:
    messages = get_json(
        "/v1/messages",
        {"endpoint_id": endpoint_id, "session_id": session_id, "after_seq": "0"},
    ).get("messages", [])
except Exception as exc:
    print(f"error: live preflight failed to read messages: {exc}", file=sys.stderr)
    sys.exit(78)

if not messages:
    print("error: live preflight expected a real history session with messages, got 0", file=sys.stderr)
    sys.exit(79)

last_text = ""
for message in messages:
    text = message.get("text") or message.get("content") or message.get("delta") or message.get("message") or ""
    text = " ".join(str(text).split())
    if text:
        last_text = text[:96]

print("live_preflight=ok")
print(f"relay={relay_url}")
print(f"backend={health.get('backend')} workers={health.get('workers')}")
print(f"endpoint_id={endpoint_id}")
print(f"session_id={session_id}")
print(f"title={title}")
print(f"source={source}")
print(f"status={status}")
print(f"messages={len(messages)}")
if last_text:
    print(f"last_message={last_text}")
PY

if [[ "$dry_run" == "1" ]]; then
  echo "dry_run=1"
  echo "No UI test launched and no live gate files were written."
  exit 0
fi

if [[ "$confirm" != "YES_SEND_TO_FIXED_HISTORY_SESSION" ]]; then
  usage
  echo "error: live full test sends, guides, and interrupts; set MKB_CONFIRM_LIVE_CODEX_FULL_TEST=YES_SEND_TO_FIXED_HISTORY_SESSION or pass --confirm-send." >&2
  exit 67
fi

export MKB_ENABLE_LIVE_CODEX_UI_TESTS=1
export MKB_LIVE_CODEX_SESSION_ID="$session_id"
export MKB_LIVE_CODEX_SESSION_TITLE="$session_title"

gate_files=(
  /tmp/MKB_ENABLE_LIVE_CODEX_UI_TESTS
  /tmp/MKB_LIVE_CODEX_SESSION_ID
  /tmp/MKB_LIVE_CODEX_SESSION_TITLE
)
cleanup_gate() {
  rm -f "${gate_files[@]}"
}
trap cleanup_gate EXIT
printf '%s\n' 'YES_MKB_LIVE_CODEX_UI_TESTS' > /tmp/MKB_ENABLE_LIVE_CODEX_UI_TESTS
printf '%s\n' "$session_id" > /tmp/MKB_LIVE_CODEX_SESSION_ID
printf '%s\n' "$session_title" > /tmp/MKB_LIVE_CODEX_SESSION_TITLE

echo "Running mutating live Company Codex UI test"
echo "session_id=$session_id"
echo "session_title=$session_title"
echo "destination=$destination"
echo "result_bundle=$result_bundle"
echo "log_path=$log_path"

set -o pipefail
xcodebuild test \
  -project MKB.xcodeproj \
  -scheme MKB \
  -destination "$destination" \
  -only-testing:MKBUITests/MKBUITests/testCodexSendGuideAndInterrupt \
  -resultBundlePath "$result_bundle" | tee "$log_path"

summary_path="${MKB_LIVE_FULL_SUMMARY:-${result_bundle%.xcresult}.summary.json}"
if xcrun xcresulttool get test-results summary --path "$result_bundle" >"$summary_path" 2>/tmp/MKB-live-full-summary.err; then
  echo "summary_path=$summary_path"
else
  echo "warning: could not extract xcresult summary" >&2
  cat /tmp/MKB-live-full-summary.err >&2
fi
