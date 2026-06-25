# iOS App

`ios-app` contains the MKB iOS consumer app and UI tests. The Codex mobile page
is implemented in `MKB/FleetWorkbench.swift`; the app shell and knowledge chat
entry live in `MKB/ContentView.swift`.

## Build

```sh
xcodebuild build -project MKB.xcodeproj -scheme MKB -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Smoke Tests

```sh
scripts/mkb_safe_smoke.sh
```

Live Company Codex tests are mutating and must target a fixed history session,
not the active work conversation. Use the scripts in `scripts/` only after
checking their preflight output.
