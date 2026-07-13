# Chromecast integration

Lume bundles the **Google Cast SDK** (v4.8.4, dynamic XCFramework) so Chromecast
works out of the box on **iOS / iPadOS**. The Cast SDK has no macOS, tvOS, or
visionOS build, so it is linked with an `ios` platform filter and all Cast code
is gated behind `#if canImport(GoogleCast)` — the other platforms compile exactly
as before. This complements the native **AirPlay** support, which needs no
third-party SDK.

## Where it lives

| Piece | Path | Role |
|---|---|---|
| Vendored SDK | `Vendor/GoogleCast/GoogleCast.xcframework` | Google Cast SDK v4.8.4 (dynamic); linked + embedded on iOS only (`platformFilter = ios`) |
| Casting seam | `Lume/Services/Player/CastService.swift` | `CastProvider` protocol (session + transport surface) + `configureGoogleCast()` registration |
| Provider | `Lume/Services/Player/GoogleCastProvider.swift` | `GCKSessionManager` / `GCKRemoteMediaClient` bridge; loads the current `PlayableMedia`, exposes play/pause/seek and polled position/duration/state |
| Cast button | `Lume/Views/Player/ChromecastButton.swift` | `GCKUICastButton` styled to match the overlay |
| Casting UI | `Lume/Views/Player/ChromecastPlaybackView.swift` | stands in for the local engine while a session is active; drives the receiver's transport and polls its playhead into the shared `PlaybackClock` |
| Launch hook | `Lume/LumeApp.swift` | calls `CastService.shared.configureGoogleCast()` |
| Session → load hook | `Lume/Views/Player/FullScreenPlayerView.swift` | `loadOntoReceiver()` casts the stream on session connect, on player open with a session already active, and on mid-cast media/resolve changes; on session end the local engine resumes at the receiver's position |
| Discovery keys | `Lume/Info.plist` | `NSBonjourServices`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription` |
| Usage-description strings | `Lume/InfoPlist.xcstrings` | localizes the two usage descriptions (all catalog languages) |

The XCFramework carries its own `PrivacyInfo.xcprivacy`, so its required-reason
API and data-use declarations are covered without editing Lume's manifest.

## Project wiring (already done)

The `xcodeproj` wiring was applied by `Scripts`-style automation, but for
reference it is: a file reference to `Vendor/GoogleCast/GoogleCast.xcframework`,
added to the **Lume** target's *Frameworks* (link) and an *Embed Frameworks* copy
phase with **Code Sign On Copy**, both with `platformFilter = ios`. The
*Embed Frameworks* phase is ordered **before** the "Inject .env secrets" run
script to avoid a build-phase dependency cycle. Build settings gained
`FRAMEWORK_SEARCH_PATHS = $(PROJECT_DIR)/Vendor/GoogleCast` and `-ObjC` in
`OTHER_LDFLAGS`.

## Receiver app ID

Uses Google's Default Media Receiver (`kGCKDefaultMediaReceiverApplicationID`,
id `CC1AD845`). To use a styled/custom receiver from the
[Google Cast Developer Console](https://cast.google.com/publish), change the id in
`CastService.configureGoogleCast()` **and** the `_CC1AD845._googlecast._tcp`
entry in `Info.plist`.

## Updating the SDK

Download a newer dynamic XCFramework and replace the vendored copy:

```bash
curl -L -o gcast.zip \
  "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-<version>_dynamic.zip"
unzip gcast.zip
rm -rf Vendor/GoogleCast/GoogleCast.xcframework
cp -R GoogleCastSDK-ios-<version>_dynamic_xcframework/GoogleCast.xcframework Vendor/GoogleCast/
```

Update `Vendor/GoogleCast/VERSION.txt`. No project changes are needed unless the
framework layout changes.

## How a cast session behaves

While a Chromecast session is active, `FullScreenPlayerView` unmounts the local
engine entirely (no double decode) and mounts `ChromecastPlaybackView` instead:
poster, receiver name, play/pause/±15s/scrubber that drive the receiver through
the `CastProvider` seam. The view polls the receiver's playhead into the shared
`PlaybackClock` every 500 ms (the Cast SDK pushes `GCKMediaStatus` only on
change), which keeps the scrubber live and — because the host persists watch
progress from that same clock at the usual boundaries — resume points and the
90%-watched flow keep working while casting.

Loading is centralized in `FullScreenPlayerView.loadOntoReceiver()`, invoked on
session connect, on player open with a session already active, and whenever
`displayMedia`'s URL changes mid-cast (Stalker resolve landing, episode/channel
switch). `GoogleCastProvider` ignores re-loads of the URL already playing, so
those edges can all call it unconditionally. When the session ends, the active
stream is rebased to the receiver's last position and the local engine resumes
there.

## Remaining work

- **On-device verification:** the integration is verified to build, link, and
  embed on the iOS simulator, but casting to a physical receiver has not been
  exercised end-to-end (discovery, load, transport, session teardown).
- **Receiver-side finish → NextUp:** when the receiver plays a VOD stream to the
  end, the session just goes idle; auto-advance to the next episode (the local
  engines' NextUp flow) isn't triggered from the receiver's `.finished` idle
  reason yet.
- **Subtitles/audio tracks on the receiver:** track selection isn't exposed
  while casting.
