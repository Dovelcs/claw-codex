#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  MKB_LIVE_CODEX_SESSION_ID=<real-history-session-id> [MKB_LIVE_CODEX_SESSION_TITLE=Test] [MKB_LIVE_CODEX_EXPECTED_TEXT=text] scripts/mkb_live_readonly_ui_test.sh
  scripts/mkb_live_readonly_ui_test.sh <real-history-session-id> [session-title] [expected-text]

Runs only the read-only Company Codex UI test:
  MKBUITests/testCodexLiveReadOnlyHistoryCanOpenFixedTestConversation

This script opens the fixed Company Codex history session and does not send,
guide, interrupt, or request a remote history load.
EOF
}

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

session_id="${MKB_LIVE_CODEX_SESSION_ID:-${1:-}}"
session_title="${MKB_LIVE_CODEX_SESSION_TITLE:-${2:-Test}}"
expected_text="${MKB_LIVE_CODEX_EXPECTED_TEXT:-${3:-}}"
destination="${MKB_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
result_bundle="${MKB_RESULT_BUNDLE_PATH:-/tmp/MKB-live-readonly-$(date +%Y%m%d-%H%M%S).xcresult}"

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
    echo "error: refusing fixture session '$session_id'; this entry is for live read-only verification." >&2
    exit 66
    ;;
esac

export MKB_ENABLE_LIVE_CODEX_UI_TESTS=1
export MKB_LIVE_CODEX_SESSION_ID="$session_id"
export MKB_LIVE_CODEX_SESSION_TITLE="$session_title"
export MKB_LIVE_CODEX_EXPECTED_TEXT="$expected_text"

gate_files=(
  /tmp/MKB_ENABLE_LIVE_CODEX_UI_TESTS
  /tmp/MKB_LIVE_CODEX_SESSION_ID
  /tmp/MKB_LIVE_CODEX_SESSION_TITLE
  /tmp/MKB_LIVE_CODEX_EXPECTED_TEXT
)
cleanup_gate() {
  rm -f "${gate_files[@]}"
}
trap cleanup_gate EXIT
printf '%s\n' 'YES_MKB_LIVE_CODEX_UI_TESTS' > /tmp/MKB_ENABLE_LIVE_CODEX_UI_TESTS
printf '%s\n' "$session_id" > /tmp/MKB_LIVE_CODEX_SESSION_ID
printf '%s\n' "$session_title" > /tmp/MKB_LIVE_CODEX_SESSION_TITLE
printf '%s\n' "$expected_text" > /tmp/MKB_LIVE_CODEX_EXPECTED_TEXT

echo "Running live read-only Company Codex UI test"
echo "session_id=$session_id"
echo "session_title=$session_title"
if [[ -n "$expected_text" ]]; then
  echo "expected_text=$expected_text"
fi
echo "destination=$destination"
echo "result_bundle=$result_bundle"

xcodebuild test \
  -project MKB.xcodeproj \
  -scheme MKB \
  -destination "$destination" \
  -only-testing:MKBUITests/MKBUITests/testCodexLiveReadOnlyHistoryCanOpenFixedTestConversation \
  -resultBundlePath "$result_bundle"
