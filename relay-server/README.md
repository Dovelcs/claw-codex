# Relay Server

`mkb_codex_relay` is the VPS-side C++ broker for the MKB mobile Codex page.
It exposes the mobile HTTP API, queues commands, tracks sessions/tasks/events,
and receives transcript/history updates from subscribed endpoints.

## Build

```sh
make -C relay-server
```

## Run

```sh
./relay-server/mkb_codex_relay 0.0.0.0 886
```

Deploy behind a firewall, VPN, or reverse proxy with authentication. The relay
accepts command and transcript mutation requests, so do not expose it
unauthenticated on the public internet.

## Main APIs

- `GET /health`
- `GET /v1/state`
- `GET /v1/messages`
- `GET /v1/message_states`
- `POST /v1/commands`
- `POST /api/history/load`
- `POST /api/workers/*`
- `POST /api/transcript/*`
