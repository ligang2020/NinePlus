# NineBot+

NineBot+ is a personal iOS app for viewing and managing Ninebot vehicle status,
with Home Screen widgets, Lock Screen widgets, Siri Shortcuts, trip history,
location views, and local ride recording.

## iOS login flow

The iOS app no longer displays a service-address or bearer-token form. The
release build contains the service URL; the only credential entered in the app
is the user's Ninebot account and password. After login, the app fetches
vehicle, status, battery, location, and trip data and stores only the returned
per-login session token.
The password is cleared from memory after login and is not persisted.

The cloud compatibility layer is the repository's `server/` service, which
invokes the MIT-licensed community `ninecli` client. This is not an official
public Ninebot developer API; Ninebot may change the user-facing cloud service
without notice. The app therefore keeps the cloud protocol behind this stable
server boundary instead of embedding an unsupported executable into iOS.

## Build and IPA

Version 8 updates the vehicle stage so parked, driving, and charging states
switch between the supplied daytime and nighttime artwork by local time. The
daytime window is 06:00–18:59, and the existing static route map and vehicle
controls remain available.

Version **13**, build **13** is configured in the Xcode project. In the
driving state, the home screen removes the cycling glyph from the vehicle-stage
badge, shows a car icon with “车辆行驶中”, and replaces current speed with the
live cumulative distance. App launch and each foreground restoration request a
fresh vehicle dashboard response.

GitHub Actions builds an unsigned device IPA and uploads it to workflow
artifacts. Pushing tag `v13` also creates or updates the matching GitHub Release
with the IPA and its SHA-256 checksum. Artifact upload needs no release secret.
If the repository blocks GitHub's automatic workflow token from creating
releases, add a fine-grained `GH_RELEASE_TOKEN` Actions secret with repository
**Contents: Read and write** permission; otherwise the workflow still succeeds
and leaves the IPA in Actions artifacts.

For a local package, use Xcode 16.4 or newer:

```bash
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer \
  scripts/package-unsigned-ipa.sh --output build/ipa-v13 --derived-data build/DerivedData-v13
```

## Backend

```bash
docker compose -f server/compose.yaml up -d --build
```

See [`server/README.md`](server/README.md) for deployment and
[`docs/ninebot-interface-analysis.md`](docs/ninebot-interface-analysis.md) for
the upstream interface boundary.

## Widgets and privacy

Widgets read the latest cached vehicle snapshot from the shared App Group
container. Do not commit account passwords, cloud tokens, signing material,
provisioning profiles, or generated build artifacts.
