# Mac App and Handoff

Velvet Thorn runs on the Mac as a Mac Catalyst app with the Mac idiom, and moves playback between iPhone, iPad and Mac in two ways: Apple Handoff, and a local-network link that also lets each device see and control the others. Owner request of 3 October 2026, chosen over a fully native AppKit target.

## Mac app

- **Target.** The `GanaBajana` target sets `SUPPORTS_MACCATALYST`, `TARGETED_DEVICE_FAMILY` `1,2,6` and `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`, so the Mac app keeps `com.agraabhi.ganabajana` and shares the App Store record, Handoff identity and iCloud container. `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` is off: the two are exclusive. `MACOSX_DEPLOYMENT_TARGET` 15.0 matches Catalyst 18. `BreezyWidgets` is built for Catalyst too. The Watch app is filtered to iOS.
- **Signing.** `Signing/MacCatalyst.entitlements` (App Sandbox, network client and server, user-selected files, the App Group and the iCloud Documents container) and `Signing/WidgetsMac.entitlements` (sandbox and App Group) apply only to `sdk=macosx*`. Native iOS signing is unchanged.
- **FFmpeg.** `tools/build-ffmpeg.py` adds `maccatalyst-arm64` and `maccatalyst-x86_64` slices (target `<arch>-apple-ios18.0-macabi`, platform `MACCATALYST`) packaged as the versioned Mac framework layout (`Versions/A`, five fixed symlinks, install name `@rpath/FFmpegBridge.framework/Versions/A/FFmpegBridge`). The iPhone device binary is byte-identical (`14e66860…`); the simulator binary differs only in its ad hoc signature. A new corresponding-source archive was produced; publishing it is a separate, unauthorized step ([FFMPEG_DISTRIBUTION.md](FFMPEG_DISTRIBUTION.md)).
- **Interface.**
  - The tabs become a sidebar (`.tabViewStyle(.sidebarAdaptable)`, Catalyst only).
  - Windows have an 820 by 620 minimum size and a hidden title (`MacWindowChrome`).
  - Sheets use page sizing (`MacSheetSizing` in `appSheetChrome()`).
  - The mini-player never hides for a keyboard (`AppPlatform.isMacDesignedForIPad` covers Catalyst).
  - The device name shows as "Mac", because Catalyst reports an iPad model name.
- **Menus and shortcuts** (`VelvetThornCommands`, also shown as the iPad keyboard shortcut overlay):
  - **Playback menu:** Play or Pause (Space), Next (⌘→), Previous (⌘←), Like Song (⌘L), Shuffle, Repeat, Now Playing (⇧⌘P) and Devices… (⇧⌘D).
  - **View menu:** Home, Search, Library and Stats (⌘1 to ⌘4), and Find (⌘F).
  - **App menu:** Settings… (⌘,).
  - New Window is removed, because every window shares one navigation state.
- **Presentations.** Catalyst builds sheet and cover hosts without the window's environment objects; the first Mac run crashed with "No Observable object of type MusicAppModel". Every `.sheet` and `.fullScreenCover` whose content reads the model applies `appPresentationEnvironment(model)` (`Sources/UI/PresentationEnvironment.swift`). A new presentation must do the same. The Devices controller is reached through `model.nearbyDevices` rather than the environment for the same reason.
- **Platform gaps.** No CarPlay, Watch or alternate icons (the App Icon row is hidden because `supportsAlternateIcons` is false). Motion and background refresh behave as macOS allows. Native StoreKit test sessions are compiled out of the Catalyst test bundle because its StoreKitTest API differs.

## Handoff

- **Publishing.** `PlaybackHandoffPublisher` owns one `NSUserActivity` of type `com.agraabhi.ganabajana.playback` (declared in `NSUserActivityTypes`).
  - It is eligible for Handoff only: never search or prediction.
  - It republishes on semantic changes: the occurrence, queue, play or pause, shuffle, repeat, Live Radio and `controlRevision`. Position ticks never publish. `userActivityWillSave` refreshes the position at save time.
  - The activity is current only while a window is active and music is selected. Live Radio, nothing selected, fixture hosts and unit hosts withdraw it.
- **Payload.** `PlaybackHandoff` version 1:
  - It carries a sender ID, sent time, whether the sender was playing, and a `PlaybackSnapshot`.
  - The snapshot is a window of at most 10 songs before and 150 after the current one, shrunk until the LZFSE-compressed JSON fits 24 KiB.
  - Original order travels only when the whole queue fits; otherwise a shuffled window plays in its own order.
  - Decoding caps decompressed bytes at 512 KiB before parsing, and validates the snapshot with `LibraryValidation`. Queues are capped at 1,024 songs.
  - Artwork that looks signed (googlevideo, `/videoplayback`, signature, expiry or token parameters) is removed. Signed media URLs, credentials and history never travel.
- **Continuing.** `.onContinueUserActivity` calls `MusicAppModel.acceptHandoff`, which ignores the device's own activity and applies the payload through `continuePlayback(from:at:startPlaying:origin:)`.
  - If the sender was playing, the position advances by the elapsed time (at most 30 seconds) and playback starts, because choosing the Handoff icon is the request. A paused sender restores paused.
  - The toast reads "Picked up from your other device."
- **The sender.** `userActivityWasContinued` pauses it. Known limitation: the sender pauses even if the receiving device then declines the payload.

## Devices (local link)

- **Discovery.** Bonjour `_ganabajana._tcp` (`NSBonjourServices`, `NSLocalNetworkUsageDescription`). The service name is a fresh UUID each launch, never the device name; display names travel only inside the encrypted session.
  - Discovery starts on an explicit action: opening Devices for the first time, or the Find Nearby Devices switch. The `nearby.enabled` and `nearby.choiceMade` flags are device-local.
  - A failed browser restarts after 5 seconds while discovery is on.
- **Security.** TLS 1.2 with a pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`), with session resumption and tickets disabled, so a replaced key cannot reconnect through a cached session.
  - **Link key:** 32 random bytes in a synchronizable Keychain item (`com.agraabhi.ganabajana.nearby-link`, data-protection keychain, available after first unlock), so devices on one iCloud account connect without pairing. The TLS PSK is derived from it with HKDF. The key is cached for 30 seconds and read again after a TLS failure.
  - **Reset Device Key** writes a new key and drops every session.
  - **Pairing fallback:** one device shows a 16-character Crockford base32 code (80 bits, four groups of four, valid 5 minutes, single use, locked after 10 TLS failures). The other device enters it. The code keys the pairing TLS session, and an X25519 exchange inside that session seals the link key for the joining device. Pairing sessions close 30 seconds after the grant or after 60 idle seconds.
- **Wire.** `NearbyLinkWire` version 1: 4-byte big-endian length frames, at most 2 MiB, rejected before buffering. Any decoding error fails closed as `malformed`.
  - Messages are `hello`, a now-playing `snapshot` (the companion snapshot plus an optional https artwork URL), companion `request` and `response`, the transfer messages, pairing, and `ping`/`pong` for round-trip time.
  - Position-only snapshot changes are published at most every 5 seconds. Receivers extrapolate positions from their own receive time, never the peer's clock.
- **Remote control.** Requests go through `CompanionPlaybackController.handle(_:origin: .nearbyDevice)` with the Watch's six-second execution lease and expected-track check. Mutations are never queued or replayed offline.
- **Moving playback.** **Play Here** pulls from a device and **Play on _device_** pushes to it:
  1. The receiver asks for an offer: the sender's full snapshot, its playing state and its exact item-clock position (`PlayerController.handoffPosition`).
  2. The receiver saves its own session, applies the offer paused, waits up to 6.5 seconds for the song to be ready, then sends Ready.
  3. Only then does the sender pause and send Released with its exact position and current playing state.
  4. The receiver re-checks the song, seeks to that position plus half the measured round trip, and plays if the sender was playing.
  - **Timing:** the receiver's budget is 12 seconds. The sender releases only within 9 seconds of its offer, and remembers a release for 15 seconds, so a late cancel makes it resume.
  - **Failures:** the receiver restores its own session paused. Live Radio, nothing selected and queues over 1,024 songs are refused with plain messages.
- **Entry points.** Settings > Account & Connection > Devices (`settings.devices`), Song Options > Devices (`player.options.devices`) and the Mac menu Devices… open the same `NearbyDevicesList`.

## Metrics

All bounded OSLog, subsystem `com.agraabhi.ganabajana`:

- **`handoff`:** `handoff_publisher`, `handoff_continued_elsewhere` and `playback_continued origin playing`.
- **`nearby`:**
  - `nearby_enabled` and `nearby_disabled`.
  - `nearby_peer_found` and `nearby_peer_lost`, with counts only.
  - `nearby_browse_results count` and `nearby_browser result=waiting code`.
  - `nearby_connect result`, `nearby_request action accepted`, `transfer phase reason duration bucket`, and pairing results.

None carries an ID, title, URL, device name, key or code.

## Coverage

- **Unit tests:**
  - `PlaybackHandoffTests` and `PlaybackHandoffPublisherTests`: codec, window, bounds, decompression cap, resume position, publication triggers, continuation and the own-activity echo.
  - `NearbyLinkProtocolTests`: framing, envelopes, bounds and the pairing code.
  - `NearbyDevicesControllerTests`, over an in-memory transport: discovery, leases, throttling, every transfer path and race, restore on failure, the choice flag, key reset, the key cache and pairing deadlines.
  - `NearbyLinkLoopbackTests`, over real TLS-PSK on 127.0.0.1: the right key connects and a wrong key fails.
  - `NearbyLinkSocketIntegrationTests`: two real controllers over loopback sockets for connect, snapshot, remote pause, a full Play Here, and a refused key.
- **Mac test target:** the full unit target also runs on Mac Catalyst through the `GanaBajanaMac` scheme.
- **UI tests:** the existing Player More and Settings suites run on iPhone.
- **Not verified:**
  - Handoff between real devices, which needs one Apple Account with Bluetooth and Wi-Fi.
  - Bonjour discovery between app processes on this Mac. The in-process browser received no results while the screen was locked, even for a shell-registered service, although a command-line browser saw it; Local Network permission could not be granted.
  - iCloud Keychain sync of the link key.
  - The Space shortcut beside text fields on the Mac.
  - Mac UI tests, which need an unlocked session.
