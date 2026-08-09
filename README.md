# NinePlus

NinePlus combines a personal iOS client with a standalone FastAPI web console
for Ninebot vehicles. The server lives in [`server/`](server/) and uses Docker
Compose for deployment on a Feiniu NAS or any Linux host with Docker.

> **Important:** the server uses `ninecli`, the community cloud client used by
> [`hasscc/ninebot`](https://github.com/hasscc/ninebot). This is not a published
> official Ninebot developer API. It calls the user-facing Ninebot cloud service
> for the signed-in account, so Ninebot can change the protocol at any time.

## Web console

The responsive web console has an Apple-inspired visual language: restrained
material surfaces, clear hierarchy, responsive layout, dark mode, reduced-motion
support, and confirmation dialogs for remote controls.

Features include:

- Ninebot account login with an HttpOnly browser session.
- Bound vehicle list and multi-vehicle switching.
- Current battery, range, mileage, speed, location, and online status.
- Battery telemetry and raw upstream payload inspection.
- Monthly ride history.
- Confirmed bell, seat-bucket, start, and stop commands supported by `ninecli`.
- Health endpoint at `/healthz` and OpenAPI documentation at `/api/docs`.

Run locally or on the NAS:

```bash
docker compose -f server/compose.yaml up -d --build
```

The service is available on port `8765` by default. See
[`server/README.md`](server/README.md) for configuration and the full API
surface. The interface analysis and security boundaries are documented in
[`docs/ninebot-interface-analysis.md`](docs/ninebot-interface-analysis.md).

## iOS app

The iOS project is under [`mini-ninebot/`](mini-ninebot/). Open
`mini-ninebot/mini-ninebot.xcodeproj` in Xcode, configure your Apple Developer
Team and App Group, then set the NinePlus server address in the app settings.

The app includes vehicle status, widgets, Siri/App Intents, ride history,
location views, and local ride recording. It is intended for personal builds
and is not configured for App Store distribution by default.

## Privacy and operational safety

- Do not commit Ninebot passwords, app tokens, certificates, or provisioning
  profiles.
- Credentials are sent only to the cloud client during login and are not stored
  by NinePlus. Browser sessions are in memory and expire on container restart.
- Keep the NAS service on a trusted LAN or put it behind HTTPS and an access
  control layer before exposing it externally.
- Use remote controls only when the vehicle is visible and in a safe state.
