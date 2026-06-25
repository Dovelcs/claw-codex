# claw-codex

Mobile Codex forwarding stack split into three deployable ends.

## Layout

- `ios-app/`: MKB iOS app, Xcode project, assets, and UI tests.
- `relay-server/`: VPS C++ relay that exposes the mobile API and brokers tasks.
- `linux-agent/`: company Linux subscribed endpoint agent for VS Code Codex IPC,
  history indexing, and transcript sync.

## Build

Build the relay server:

```sh
make -C relay-server
```

Build the Linux subscribed endpoint agent:

```sh
make -C linux-agent
```

Build the iOS app from Xcode or with xcodebuild:

```sh
xcodebuild build -project ios-app/MKB.xcodeproj -scheme MKB -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Security Notes

Do not commit service tokens, API keys, SSH keys, or deployment passwords. The
iOS knowledge API key is read from `MKB_CODEX_API_KEY` for local debug builds;
production deployments should route privileged calls through a protected
backend instead of embedding service secrets in the app binary.
