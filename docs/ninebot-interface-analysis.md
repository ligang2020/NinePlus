# Ninebot interface analysis

## Source and boundary

NinePlus is informed by the public Home Assistant integration at
[`hasscc/ninebot`](https://github.com/hasscc/ninebot) and uses the current
`ninecli` release that the integration depends on. The installed `ninecli`
0.1.7 package is a small Python launcher around a bundled Go binary; it does
not expose the old `ninecli.api.NinebotCloud` Python class.

That distinction matters: this is **not a published official Ninebot developer
API**. `ninecli` is a community client for the user-facing Ninebot Passport and
business services. The upstream service can change login, payloads, hostnames,
anti-abuse checks, or supported controls without notice.

## Observed client surface

The actual binary exposes these commands:

| ninecli command | NinePlus route | Purpose |
| --- | --- | --- |
| `login --user ... --password ...` | `POST /auth/login` | Authenticate the account |
| `vehicles` | `GET /vehicles` | List owned/shared vehicles |
| `status SN` | `GET /vehicles/{sn}/status` | Location, battery, lock, ACC, permissions |
| `battery SN` | `GET /vehicles/{sn}/battery` | Battery voltage, temperature, cycles, charge data |
| `travel SN --month YYYYMM` | `GET /vehicles/{sn}/travel` | Ride history |
| `travel SN --detail ID` | `GET /vehicles/{sn}/travel/{id}` | One ride detail |
| `bell SN` | `POST /vehicles/{sn}/control` | Find-my-vehicle bell |
| `buck SN` | `POST /vehicles/{sn}/control` | Seat-trunk control |
| `engine-start SN` / `engine-stop SN` | `POST /vehicles/{sn}/control` | Power/unlock or power/lock |

The binary also includes a `serve` mode that exposes a REST proxy on
`127.0.0.1:18009` by default. NinePlus invokes the binary directly instead so
each browser login gets an isolated token directory and cannot share another
user's cloud session.

The CLI help identifies the default service families as Passport, business,
motor, e-bike, and travel hosts. NinePlus deliberately does not hard-code those
URLs; the binary remains the compatibility boundary.

## Security and reliability boundaries

- Login credentials are passed to the `ninecli` process only for the login
  command. Authenticated tokens are kept in a per-session directory mounted on
  container tmpfs, never in the Git repository or host `server/data` volume.
- Browser sessions are represented only by an HttpOnly cookie. A container
  restart clears the tmpfs and logs out all users.
- Each session has a lock so the stateful CLI config is not used concurrently.
  The subprocess has a configurable timeout and is run off the FastAPI event
  loop.
- Remote controls require explicit confirmation in both the browser and API.
  Use them only when the vehicle is visible and in a safe state.
- The default Compose deployment is LAN-oriented. Put it behind HTTPS and an
  access-control layer before exposing it outside the trusted network.
