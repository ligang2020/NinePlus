# Ninebot interface analysis

## What is actually being used

NinePlus is built around the public Home Assistant integration at
[`hasscc/ninebot`](https://github.com/hasscc/ninebot). That integration delegates
its cloud work to the `ninecli` Python package (`ninecli==0.1.7` in the
integration version reviewed for this project).

The important distinction is that this is **not a published official Ninebot
Open API**. The package talks to the user-facing Ninebot cloud service on behalf
of an authenticated account. Ninebot may change login, endpoints, payloads,
anti-abuse checks, or supported control commands without notice.

## Observed cloud surface

The integration/client surface used by the server is:

| ninecli method | NinePlus route | Purpose |
| --- | --- | --- |
| `initialize()` | `POST /auth/login` | Authenticate a Ninebot account |
| `get_user_vehicles()` | `GET /vehicles` | List bound vehicles |
| `get_current_vehicle_data(sn)` | `GET /vehicles/{sn}/status` | Current telemetry and location |
| `get_battery_info(sn)` | `GET /vehicles/{sn}/battery` | Battery telemetry |
| `get_vehicle_travel(sn, page, page_size, month)` | `GET /vehicles/{sn}/travel` | Ride history |
| `get_travel_detail(sn, travel_id)` | `GET /vehicles/{sn}/travel/{id}` | One ride detail |
| `set_vehicle_control(sn, control_type, control_value)` | `POST /vehicles/{sn}/control` | Supported remote controls |

NinePlus intentionally keeps upstream response fields tolerant and preserves
raw response data in the dashboard because fields differ by vehicle family and
firmware version.

## Security boundaries

- Ninebot credentials are sent only to the cloud client during login and are
  never written to the repository or `/data`.
- Browser sessions are stored in memory and represented to the browser only by
  an HttpOnly cookie. A container restart invalidates all sessions.
- Cloud calls are serialized per account and run off the FastAPI event loop so a
  synchronous client cannot block other HTTP requests. Calls also have a
  configurable timeout.
- Remote controls require an explicit confirmation in the API request and in
  the UI. Use them only when the vehicle is in sight and in a safe state.
- The default Compose deployment is LAN-oriented. Put it behind HTTPS and an
  access-control layer before exposing it outside the trusted network.
