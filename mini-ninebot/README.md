# mini-ninebot

NineBot+ iOS app, version **1.2.69** (build **69**).

The app's first screen is the **NinePlus account login**. The service URL is
built in, and no installation-wide access token or token secret is required.
The app stores only the returned per-user NinePlus session token.

The app talks to the companion NinePlus service, which uses the community
`ninecli` cloud compatibility client. It is not an official public Ninebot
developer API. The official Ninebot cloud binding is configured once on the
server and reused by every device; the iOS app never asks each device for that
password. Cached vehicle data may be kept locally for a smoother dashboard.
