# Native CarPlay audio

Breezy’s CarPlay interface uses native library lists and the system’s shared Now Playing screen. Playback and saved-library mutations go through the same `CompanionPlaybackController` as the phone’s other companion surfaces.

**Verification status:** the native scene, shared bridge, target membership, and opt-in entitlement declaration are configured. The CarPlay suites passed in `Breezy-Companions-Unit-02`, including the Objective-C callback registration check. The phone run's album-license failure remains recorded alongside a separate passing follow-up in [VERIFICATION.md](VERIFICATION.md). All four signing configurations were inspected, and the standard signed Debug phone/Watch build passed. Native head-unit acceptance and CarPlay entitlement/profile approval remain pending.

## Project and runtime integration

### App startup

`GanaBajanaApp.init()` installs the bridge using the selected Debug/Release `MusicAppModel`, before scenes connect:

```swift
_model = State(initialValue: model)
let companionPlayback = CompanionPlaybackController(model: model)
CompanionRuntime.playback = companionPlayback
```

The phone Watch session and CarPlay use that same instance. The CarPlay delegate resolves `CompanionRuntime.playback`; it never constructs a model or player. App initialization makes the bridge available before a phone view appears, including a CarPlay-only launch. If the registry is unavailable, each list presents **Breezy isn’t ready** with **Retry**, which checks the registry again.

### Static scene configuration

`project.yml` declares this CarPlay role in the app’s scene manifest:

```yaml
UIApplicationSceneManifest:
  UIApplicationSupportsMultipleScenes: true
  UISceneConfigurations:
    CPTemplateApplicationSceneSessionRoleApplication:
      - UISceneConfigurationName: CarPlay
        UISceneClassName: CPTemplateApplicationScene
        UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).CarPlaySceneDelegate
```

`CarPlaySceneDelegate` is a `@MainActor final` subclass of `UIResponder` implementing the SDK’s Swift audio callbacks `templateApplicationScene(_:didConnect:)` and `templateApplicationScene(_:didDisconnectInterfaceController:)`. Its Objective-C runtime name is `GanaBajana.CarPlaySceneDelegate`, matching the module-qualified manifest. Compilation uses the SDK-imported method names; `CarPlaySceneDelegateTests` confirms the selectors `templateApplicationScene:didConnectInterfaceController:` and `templateApplicationScene:didDisconnectInterfaceController:` are exposed to Objective-C.

The SwiftUI `WindowGroup` supplies the phone scene. `PhoneSceneLifecycle` reads the phone window’s own phase for listening checkpoints and release refresh, so an active CarPlay scene does not mask the phone window entering the background. CarPlay uses only its supplied `CPInterfaceController`, without another phone window or root view controller. `Sources/CarPlay/` belongs to the iOS app target, and `Tests/CarPlay*.swift` belongs to `GanaBajanaTests`.

### Audio entitlement

Use **`GanaBajana` or `GanaBajanaWatch` for normal development and automatic signing**. Phone `Debug` and `Release` request iCloud through `Signing/iCloud.entitlements`, without the managed CarPlay capability; the Watch uses no custom entitlement file. The opt-in CarPlay file includes both capabilities. The earlier default configuration requested CarPlay without a provisioned profile, causing the reported automatic-signing failure.

The optional **`GanaBajanaCarPlay`** scheme uses `Debug-CarPlay` for Run/Test and `Release-CarPlay` for Archive. Only those iPhone configurations select [`Signing/CarPlay.entitlements`](../Signing/CarPlay.entitlements):

```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

This is a valid [Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-audio), but declaring it does not grant the capability to an App ID or an existing provisioning profile. Use the opt-in scheme only after [Apple approves the CarPlay capability](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements) and the profile includes it. The Watch target does not request this entitlement; do not manually add the key there.

CarPlay source and the static scene manifest remain in the normal iPhone build, but the custom CarPlay app requires the opt-in scheme and approved profile. Both Release configurations exclude `TipJar.storekit`. The signing correction changes local configuration, not the developer account or provisioning approval. The existing content-rights release hold in [release status](app-store/RELEASE_STATUS.md) also applies.

## Browsing and playback

| Surface | Behavior |
| --- | --- |
| Favorites | Plays a selected saved favorite in the bridge-provided order |
| Recently played | Browses the saved recent history; an empty list explains the listening-history dependency |
| Playlists | Opens the selected playlist, then plays a song in that playlist |
| Queue | Selects the exact queued occurrence through the bridge’s `MusicAppModel.playQueueTrack(at:)` path |
| Now Playing | Uses `CPNowPlayingTemplate.shared`, populated by the phone’s existing `MPNowPlayingInfoCenter` metadata |
| Up Next, labeled Queue | The Now Playing observer opens the native Queue list |

The root uses four `CPListTemplate` tabs when the SDK permits four audio tabs. A lower tab limit uses the bridge’s `root` library list. Each list uses one section and respects the current `CPListTemplate.maximumItemCount` and `maximumSectionCount`. A bridge-truncated or vehicle-limited page displays a **More on iPhone** section header. The bridge owns its page-size bound; CarPlay does not invent a continuation token or reinterpret an omitted item’s index.

The first root is a loading view. Library reads start after root installation is submitted and yield between initial tabs. iOS 18.4 and later use the native empty-list spinner; iOS 18.0–18.3 show loading text. Empty libraries have specific explanations and a **Reload** navigation button. Recoverable selection and navigation errors offer **Retry**. True playback failures in `CompanionNowPlaying.errorMessage` have a native error list whose Retry sends a fresh, track-scoped `.play` request. The bridge’s privacy-safe message is displayed unchanged; raw provider errors stay on the phone.

`CompanionSnapshot.libraryError` reports a separate library failure. An unsuccessful operation carrying that field displays **Library needs attention** with the bridge’s phone-recovery message. A failed browse or list selection offers **Reload**, which only sends `.browse` and can reflect recovery performed on the phone. A failed playback-screen action offers **Now Playing**, which navigates back without retrying the failed write or sending a playback command. A background library-error snapshot alone never presents a playback error or interrupts active audio. A genuine playback error still supports Retry even when a library error also exists.

Playable selections send the displayed page’s `location`, opaque `item.id`, and `revision` unchanged in `.playItem`. The bridge checks revisions against the current full ordering. A reordered queue therefore produces a reloadable error rather than playing whichever song inherited an old row index. Queue selection preserves the phone model’s radio and playback-intent handling.

The phone’s `PlaybackSystemControls` remains responsible for AVAudioSession, `MPRemoteCommandCenter`, and metadata. CarPlay’s native play/pause, previous/next, and seek controls use that existing transport. Three snapshot-driven `CPNowPlayingImageButton` controls provide shuffle, repeat, and favorite. Repeat cycles Off → All → One → Off. The custom image buttons support an explicit selected state from the bridge, and their requests include the displayed track ID. No remote-command targets or Now Playing metadata are registered by CarPlay.

List artwork uses system symbols. There are no CarPlay image downloads or media-resolution waits in list handlers.

## Callback and lifecycle rules

- **Connect:** create the loading root, configure shared Now Playing and its three buttons, install the Up Next observer, attach the bridge observer, then submit the root. Now Playing is configured before the connection method returns, including when the system opens it directly.
- **List selection:** Apple documents list-item handlers on the main queue. `defer { completion() }` stays in the SDK handler, outside the synchronous `MainActor.assumeIsolated` block. This keeps the SDK’s non-Sendable completion on the same callback stack rather than transferring it across isolation. Completion runs once for retired rows, rejected requests, and disconnected sessions, acknowledging synchronous handling while AVPlayer preparation continues under the phone controller.
- **Other callbacks:** the native interface adapter supplies nonnil completions for root, push, pop, and pop-to-root operations. It converts errors to strings and explicitly hops to the main actor. The unannotated Now Playing observer also hops before touching state. Up Next checks that Now Playing is still visible after that hop.
- **Navigation:** one native operation is submitted at a time. A newer destination replaces pending intent. An older completion can finish its own operation but cannot display its error or continue its abandoned navigation. Native tab changes retire pending navigation. An existing Now Playing template is popped to rather than pushed twice. At the five-template depth limit, navigation pops to the selected tab’s root before opening the destination.
- **Freshness:** connection IDs retire old scene callbacks; bridge-binding IDs reject old observers; snapshot sequence checks reject older state within a session; render IDs retire replaced rows and Retry buttons. A row from a different bridge session requires a reload. Extra controls recheck the displayed favorite/shuffle/repeat value against a fresh bridge snapshot before applying the change, and their requests carry the expected track ID.
- **Refresh:** the visible list refreshes when bridge state changes and when it appears. Position-only updates do not rebuild library rows. Identical pages retain their rows; changed vehicle limits are applied when the list reloads. Background snapshot refresh does not dismiss error notices.
- **Disconnect:** cancel only CarPlay UI work, remove this bridge observation token and this Now Playing observer, disable this session’s extra buttons, and clear delegates only if they still point to this session. CarPlay does not pause playback, clear shared metadata, or remove the phone’s remote-command registrations.

A failed root presentation gets one plain-list fallback with Retry. If the vehicle rejects the fallback too, the session records `event=fallback_root_template_failed`; reconnecting supplies a new interface controller. A failed navigation without a visible source list gets one error-list presentation attempt. These paths do not loop indefinitely.

CarPlay emits local `OSLog` events in category `CarPlay` for root and navigation presentation failures. It adds no network analytics or metric dimensions.

## Files

| File | Responsibility |
| --- | --- |
| `Sources/CarPlay/CarPlaySceneDelegate.swift` | Audio scene lifecycle and interface identity |
| `Sources/CarPlay/CarPlaySessionController.swift` | Bridge binding, library requests, selection, errors, and UI lifecycle |
| `Sources/CarPlay/CarPlayListTemplates.swift` | Native list construction, loading/error states, limits, and one-shot selection completion |
| `Sources/CarPlay/CarPlayNowPlayingControls.swift` | Shared Now Playing configuration, extra controls, and Up Next observation |
| `Sources/CarPlay/CarPlayTemplateNavigator.swift` | Serialized, latest-intent template navigation with depth limits |
| `Sources/CarPlay/CarPlayInterfaceTransport.swift` | Injectable interface boundary and native callback actor handoff |

`Sources/Core/Companion/CompanionProtocol.swift`, `Sources/Companion/CompanionPlaybackController.swift`, and `Sources/Companion/CompanionRuntime.swift` supply the shared contract and runtime. CarPlay uses their synchronous API and value types directly. Its local requests leave the optional `executionLease` nil; Watch transport owns lease-based expiry.

## Test coverage

These suites passed within `Breezy-Companions-Unit-02`. The selectors remain available for focused checks; [VERIFICATION.md](VERIFICATION.md) owns the full phone-run counts and its separate album-parser follow-up.

```text
-only-testing:GanaBajanaTests/CarPlayTemplateTests
-only-testing:GanaBajanaTests/CarPlayNavigationTests
-only-testing:GanaBajanaTests/CarPlaySessionTests
-only-testing:GanaBajanaTests/CarPlayPlaybackIntegrationTests
-only-testing:GanaBajanaTests/CarPlaySceneDelegateTests
```

| Suite | Coverage |
| --- | --- |
| `CarPlayTemplateTests` | Real CP template construction, Now Playing configured before root completion, tab fallback, loading/empty views, opaque row IDs, item/section bounds, truncation, retained Retry, and retired row callbacks |
| `CarPlayNavigationTests` | Delayed native completions, latest-intent success/failure handling, duplicate Now Playing avoidance, depth-limit recovery, native-navigation cancellation, disconnect, and background-callback delivery on the main actor |
| `CarPlaySessionTests` | Actual `CompanionPlaybackController` with isolated `MusicAppModel` fixtures: preinstalled runtime, unavailable/replaced-registry retry, playlist play, queue revision rejection/reload, radio-intent cancellation, overlapping selections, persisted favorite and shuffle/repeat mutations, stale-track/state controls, sanitized stream-error retry with and without a concurrent library error, read-only library reload after phone recovery, Up Next and its presentation-failure retry, root fallback, and reconnect |
| `CarPlayPlaybackIntegrationTests` | Real phone AVPlayer with a local WAV fixture for disconnect continuity, authoritative metadata and command enabled state, preservation of another bridge observer/delegate, rejection of a late resolver failure after a newer phone selection, and active-playback library-write failure without an audio restart or playback-retry loop |
| `CarPlaySceneDelegateTests` | Objective-C runtime visibility of both SDK audio-scene callback selectors |

`Tests/CarPlayTestSupport.swift` supplies a controllable interface transport with per-tab stacks and delayed completions. The application model, companion controller, library persistence, and playback mutation paths are real; existing provider gates isolate network work. The controls’ `activate` entry point is the same route invoked by native button callbacks. These tests do not synthesize a successful physical CarPlay connection.

## Device acceptance boundary

The feature's Swift 6 compilation and scoped tests passed. `Breezy-Companions-Release-02` was an unsigned generic-iOS build including Watch. After the configuration split, `Breezy-Standard-Signing-01` passed a standard signed Debug device build and deep signature checks, without the CarPlay entitlement. The opt-in CarPlay scheme still needs an approved profile and a native head unit to verify cold CarPlay-only launch, direct system Now Playing entry, steering-wheel input and reconnect. Native button accessibility and vehicle rendering remain unverified.

The local WAV test exercises the existing phone AVPlayer through an injected CarPlay interface. It cannot establish audible vehicle output, actual head-unit presentation, background suspension behavior, or signing entitlement approval. A physical cable or wireless disconnect may independently trigger the phone’s existing audio-route-change pause policy; the CarPlay scene’s disconnect handler itself sends no pause.

## API references reviewed

- [Displaying content in CarPlay](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay): static scene role and audio callbacks without a window.
- [Requesting CarPlay entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements): audio capability approval and provisioning requirements.
- [CPListItem.handler](https://developer.apple.com/documentation/carplay/cplistitem/handler): main-queue delivery and required selection completion.
- [CPTabBarTemplate](https://developer.apple.com/documentation/carplay/cptabbartemplate): each tab has its own navigation hierarchy; tab bars are root templates.
- [CPListTemplate.maximumItemCount](https://developer.apple.com/documentation/carplay/cplisttemplate/maximumitemcount): vehicle-dependent list bounds.
- [CPNowPlayingTemplate](https://developer.apple.com/documentation/carplay/cpnowplayingtemplate): shared instance, authoritative MediaPlayer information, and Up Next observation.
- [CPNowPlayingImageButton](https://developer.apple.com/documentation/carplay/cpnowplayingimagebutton): native custom-image controls and monochrome artwork.

The installed `iPhoneOS.sdk/System/Library/Frameworks/CarPlay.framework/Headers/` supplied the concrete actor annotations, five-extra-button limit, and nonnil-completion failure contract. The implementation uses APIs available at the app’s iOS 18 minimum, with the empty-list spinner explicitly gated at iOS 18.4.
