# NinePlus Server

NinePlus Server is a standalone FastAPI web console for the current `ninecli`
Ninebot client. It provides an Apple-inspired responsive interface for vehicle
status, battery details, location, ride history, and confirmed remote controls.

> **Important:** `ninecli` is a community client for the user-facing Ninebot
> cloud service. This project does not contain or claim an official public
> Ninebot developer API. Ninebot can change the service at any time.

## Run with Docker Compose

```bash
cd server
docker compose up -d --build
```

The service listens on `8765`. The authenticated CLI token directories live on
container tmpfs, while no account password or cloud token is persisted to the
host. Restarting or recreating the container logs out all users.

Open `http://NAS_IP:8765` on the trusted LAN. OpenAPI documentation is at
`/api/docs` and the health probe is at `/healthz`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `NINEPLUS_SESSION_TTL` | `2592000` | Browser session lifetime in seconds |
| `NINEPLUS_CLI_TIMEOUT` | `45` | Timeout for a ninecli operation |
| `NINEPLUS_SESSION_ROOT` | `/run/nineplus/sessions` | Ephemeral token directory |
| `NINEPLUS_COOKIE_SECURE` | `auto` | `true` for HTTPS-only cookie, `false` for plain LAN HTTP |
| `NINEPLUS_LOG_LEVEL` | `INFO` | Server log level |
| `NINEPLUS_NINECLI_BIN` | `ninecli` | CLI executable override |

For an HTTPS reverse proxy, set `NINEPLUS_COOKIE_SECURE=true`.

## API envelope

Successful responses use:

```json
{"ok": true, "data": {}}
```

Errors use:

```json
{"ok": false, "error": {"code": "...", "message": "..."}}
```

`POST /vehicles/{sn}/control` requires `{ "action": "bell", "confirm": true }`.
The supported actions are `bell`, `buck`, `engine_start`, and `engine_stop`.

## Update on the NAS

```bash
git pull --ff-only
docker compose -f server/compose.yaml up -d --build
docker compose -f server/compose.yaml ps
curl http://127.0.0.1:8765/healthz
```
