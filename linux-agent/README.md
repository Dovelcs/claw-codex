# Linux Subscribed Endpoint Agent

`mkb_codex_linux_agent` runs on the company Linux host that owns the VS Code
Codex session history. It is a single C++ executable that forks internal worker
and history-sync modes:

- VS Code Codex IPC task forwarding.
- Codex session index publication from `~/.codex/session_index.jsonl`.
- Lazy history transcript loading from `~/.codex/sessions`.
- Batched transcript upload to the relay, with per-message fallback for older
  relay deployments.

The periodic history-index sync publishes titles only. Transcript content is
loaded by the separate request worker using `--requests-only`, so opening an
uncached conversation does not trigger a full history rollout.

## Build

```sh
make -C linux-agent
```

## Run

```sh
./linux-agent/mkb_codex_linux_agent --broker http://124.174.101.22:886
```

Useful environment variables:

```sh
MKB_CODEX_WORKER_VSCODE_IPC_SOCKET=/tmp/codex-ipc/ipc-1000.sock
MKB_CODEX_AGENT_HISTORY_INTERVAL=300
MKB_CODEX_AGENT_HISTORY_REQUEST_INTERVAL_MS=100
MKB_CODEX_HISTORY_LIMIT=500
MKB_CODEX_HISTORY_REQUEST_LIMIT=20
MKB_CODEX_SESSION_INDEX=~/.codex/session_index.jsonl
MKB_CODEX_SESSIONS_ROOT=~/.codex/sessions
```
