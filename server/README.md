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

Open `http://NAS_IP:8765` on the trusted LAN for the web console. The iOS
release has the service URL and installation token injected at build time, so
its UI only asks for the Ninebot account. OpenAPI documentation is at
`/api/docs` and the health probe is at `/healthz`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `NINEPLUS_SESSION_TTL` | `2592000` | Browser session lifetime in seconds |
| `NINEPLUS_CLI_TIMEOUT` | `45` | Timeout for a ninecli operation |
| `NINEPLUS_CACHE_TTL_VEHICLES` | `30` | Per-session vehicle-list cache in seconds |
| `NINEPLUS_CACHE_TTL_STATUS` | `8` | Per-session vehicle-status cache in seconds |
| `NINEPLUS_CACHE_TTL_BATTERY` | `15` | Per-session battery cache in seconds |
| `NINEPLUS_CACHE_TTL_TRAVEL` | `60` | Per-session travel cache in seconds |
| `NINEPLUS_SESSION_ROOT` | `/run/nineplus/sessions` | Ephemeral token directory |
| `NINEPLUS_COOKIE_SECURE` | `auto` | `true` for HTTPS-only cookie, `false` for plain LAN HTTP |
| `NINEPLUS_ACCESS_TOKEN` | required | Installation-wide API access token; send as `Authorization: Bearer` or `X-NinePlus-Access-Token` |
| `NINEPLUS_LOG_LEVEL` | `INFO` | Server log level |
| `NINEPLUS_NINECLI_BIN` | `ninecli` | CLI executable override |
| `NINEPLUS_DEVICE_ID` | generated | 32-character device ID used by the cloud login client |
| `NINEPLUS_PORTAL_USERNAME` | `gang` | NinePlus 自有登录用户名 |
| `NINEPLUS_PORTAL_PASSWORD` | required | NinePlus 自有登录密码，只放在 `server/.env` |

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

`GET /dashboard` returns the home-screen vehicle list, current status,
battery, and current-month travel data in one response. It is the preferred
endpoint for the iOS dashboard; the underlying reads are protected by a
per-login short-lived cache and identical in-flight requests are coalesced.
`GET /vehicles/{sn}/travel` accepts `month=YYYY-MM` (or `YYYYMM`), `page`, and
`page_size`. Vehicle serial numbers and travel IDs are validated
before they are passed to `ninecli`. The server creates a per-installation
client config with a non-placeholder device ID; set `NINEPLUS_DEVICE_ID` to a
real captured value when the upstream service requires device binding. Expired
in-memory sessions are removed
periodically, and their ephemeral token directories are deleted at the same
time.

## Update on the NAS

```bash
git pull --ff-only
docker compose -f server/compose.yaml up -d --build
docker compose -f server/compose.yaml ps
curl http://127.0.0.1:8765/healthz
```

## iOS 登录流程

正式版 iOS App 使用 `Authorization: Bearer <NINEPLUS_ACCESS_TOKEN>` 作为
安装级访问凭据调用 `POST /ninebot/login`。服务端会为 App 自动创建轻量会话，
再把九号手机号/邮箱和密码交给 `ninecli`；接口返回的会话令牌随后用于
`/dashboard`、车辆状态、电池、行程和控制接口。

网页控制台仍然保留独立的两步登录：先 `POST /auth/login` 登录本地门户，
再调用 `POST /ninebot/login` 绑定九号官方账号。两种入口共享持久化的云端绑定，
但不会把九号密码写入响应或日志。
