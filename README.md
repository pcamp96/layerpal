# LayerPal

An iPhone app for [Bambuddy](https://github.com/maziggy/bambuddy), the self-hosted print farm manager for Bambu Lab printers. LayerPal talks to your own Bambuddy server over its REST API and WebSocket. It doesn't need a modified Bambuddy.

LayerPal is an independent project. It isn't affiliated with Bambuddy or Bambu Lab.

## What it does

- Farm overview with live status, progress, layers, time left and errors for every printer
- One Live Activity on the Lock Screen and Dynamic Island covering all active prints
- Push notifications for finished, failed and paused prints, printer errors and more
- Printer controls: pause, resume, stop, lights, speed, temperatures, load and unload filament, clear the plate
- Camera feeds
- Print queue, filament mapping, archives, library and projects
- Spool inventory (built-in or Spoolman), maintenance, stats, and user and server admin

Printers in Bambu cloud mode are watch-only. Bambu only lets third-party software control printers that are in LAN-only mode with Developer Mode on.

## Requirements

- A Bambuddy server your phone can reach (1.3.0 or newer recommended)
- iOS 17.2 or newer
- To build: a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill in your Apple Team ID, your bundle ID and your relay URL. The local file is gitignored.
2. Run `xcodegen` in the repo root, then open `LayerPal.xcodeproj`.
3. Let Xcode create the App ID, the App Group (`group.<your bundle ID>`) and the Push Notifications capability.
4. Run on your iPhone. In the app, enter your Bambuddy address and sign in, or paste an API key.

Run the unit tests with the `LayerPal` scheme (`Cmd+U`).

## Push notifications and the relay

Apple only delivers pushes to an app from a server holding that app's APNs key, so LayerPal uses a small relay: a Cloudflare Worker in the [layerpal-relay](../layerpal-relay) project.

- The app registers the phone with the relay and installs a webhook notification provider in Bambuddy that points at it. Bambuddy's stock webhook provider does the rest.
- For Live Activities, the relay polls Bambuddy's status once a minute with a read-only API key, encrypted at rest.
- The relay stores your phone's push tokens, your Bambuddy address and that read-only key. It doesn't store print files, camera images or account passwords.

To run your own relay, deploy `layerpal-relay` with your APNs key and point `RELAY_URL` at it. With `RELAY_URL` empty, the app works without push or Live Activity updates.

Debug builds register as APNs `sandbox`; TestFlight and App Store builds register as `production`.

## License

MIT. See [LICENSE](LICENSE).
