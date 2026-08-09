# NinePlus Server

NinePlus Server is a standalone FastAPI web console for the cloud client used
by [`hasscc/ninebot`](https://github.com/hasscc/ninebot). It provides an Apple-
inspired responsive interface for vehicle status, battery details, location,
ride history, and confirmed remote controls.

> **Important:** `ninecli` is a community client for the user-facing Ninebot
> cloud service. This project does not contain or claim an official public
> Ninebot developer API. Ninebot can change the service at any time.

## Run with Docker Compose

```bash
cd server
docker compose up -d --build
```

The service listens on `8765` and stores only runtime data under `server/data`.
The browser session itself is held in memory; restarting the container logs out
all users. No account password or cloud token is persisted by NinePlus.

Open `http://NAS_IP:8765` on the trusted LAN. The OpenAPI schema is available at
`/api/docs`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `NINEPLUS_PORT` | `8765` | Documented host port; Compose uses host networking |
| `NINEPLUS_SESSION_TTL` | `2592000` | Browser session lifetime in seconds |
| `NINEPLUS_CLOUD_TIMEOUT` | `30` | Timeout for a Ninebot cloud operation |
| `NINEPLUS_COOKIE_SECURE` | `auto` | `true` for HTTPS-only cookie, `false` for plain LAN HTTP |
| `NINEPLUS_LOG_LEVEL` | `INFO` | Server log level |

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
