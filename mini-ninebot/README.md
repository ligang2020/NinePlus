# mini-ninebot

NineBot+ iOS app, version **1.2.65** (build **65**).

The app's first screen is the Ninebot account login. The service URL is
built in, and no NinePlus installation access token or token secret is required.
The app stores only the returned per-login session token.

The app talks to the companion NinePlus service, which uses the community
`ninecli` cloud compatibility client. It is not an official public Ninebot
developer API. Account passwords are sent only for the login request and are
cleared after a successful login; the app persists the returned session token
and cached vehicle data.
