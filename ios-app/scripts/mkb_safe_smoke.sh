#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

destination="${MKB_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
stamp="$(date +%Y%m%d-%H%M%S)"
result_bundle="${MKB_RESULT_BUNDLE_PATH:-/tmp/MKB-safe-smoke-${stamp}.xcresult}"
log_path="${MKB_SAFE_SMOKE_LOG:-${result_bundle%.xcresult}.log}"

# Do not let a caller's shell accidentally enable live Company Codex tests.
unset MKB_ENABLE_LIVE_CODEX_UI_TESTS
unset MKB_LIVE_CODEX_SESSION_ID
unset MKB_LIVE_CODEX_SESSION_TITLE
unset MKB_LIVE_CODEX_EXPECTED_TEXT
rm -f /tmp/MKB_ENABLE_LIVE_CODEX_UI_TESTS
rm -f /tmp/MKB_LIVE_CODEX_SESSION_ID
rm -f /tmp/MKB_LIVE_CODEX_SESSION_TITLE
rm -f /tmp/MKB_LIVE_CODEX_EXPECTED_TEXT

echo "Running safe MKB smoke"
echo "destination=$destination"
echo "result_bundle=$result_bundle"
echo "log_path=$log_path"
echo "live_tests=skipped-explicitly"

set -o pipefail
xcodebuild test \
  -project MKB.xcodeproj \
  -scheme MKB \
  -destination "$destination" \
  -skip-testing:MKBUITests/MKBUITests/testCodexSendGuideAndInterrupt \
  -skip-testing:MKBUITests/MKBUITests/testCodexLiveReadOnlyHistoryCanOpenFixedTestConversation \
  -resultBundlePath "$result_bundle" | tee "$log_path"

summary_path="${MKB_SAFE_SMOKE_SUMMARY:-${result_bundle%.xcresult}.summary.json}"
if xcrun xcresulttool get test-results summary --path "$result_bundle" >"$summary_path" 2>/tmp/MKB-safe-smoke-summary.err; then
  echo "summary_path=$summary_path"
else
  echo "warning: could not extract xcresult summary" >&2
  cat /tmp/MKB-safe-smoke-summary.err >&2
fi
