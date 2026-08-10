# mini-ninebot

NineBot+ iOS app, version **1.2.61** (build **61**).

The app's first screen is the Ninebot account login. Service address and
installation access token are build-time configuration values; they are not
shown as user-editable fields. GitHub Actions injects the repository secret
`NINEPLUS_ACCESS_TOKEN` when packaging the IPA.

The app talks to the companion NinePlus service, which uses the community
`ninecli` cloud compatibility client. It is not an official public Ninebot
developer API. Account passwords are sent only for the login request and are
cleared after a successful login; the app persists the returned session token
and cached vehicle data.
