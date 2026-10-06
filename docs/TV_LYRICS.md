# TV Lyrics

## Status and Audio Contract

The R17 presentation is implemented and integrated with the app/model, shared lyrics selection and scene manifest.
Core-03, Integration-03 and UI-02 passed in their targeted scope, including phone light/dark and source-text checks.
[VERIFICATION.md](VERIFICATION.md) owns counts and run boundaries. Physical TV lyrics remain unverified.

The owner reports constant physical testing and actual TV audio AirPlay working great. This closes existing
audio acceptance as an owner report, not acceptance of the new lyrics presentation. Keep
`PlaybackAudioRoute.makePlayer()` with `allowsExternalPlayback = false` and the
`.playback` / `.longFormAudio` session policy. This feature has no audio-session or playback writes.
[AIRPLAY.md](AIRPLAY.md) describes the existing audio implementation and its historical evidence.

## Listener Experience

**TV Lyrics** opens a full-screen, black phone view with large white text. Rotating the phone gives lyrics more
width. The page says: “For TV, open Control Center and choose Screen Mirroring. Rotate this device for a wider
view.” Screen Mirroring is a system action; the app neither opens it through a private URL nor detects it from
an audio route. Ordinary audio-only AirPlay does not imply an external screen or carry custom video.

When iOS supplies a separate, noninteractive external-display scene, the same presentation appears there after
opt-in. Connecting alone leaves that scene black. **Lyrics Options**, offered only with a separate scene,
returns to the phone's existing lyrics choices while that external presentation continues. Changing the chosen
document, including a published Latin alternative, updates the shared presentation. **Stop TV Lyrics** is available
in the full-screen view and in `TVLyricsStartButton` while enabled. Stop clears content on every external scene.
The OS retains the scene connection with a black app-owned window; the app does not destroy the session or
alter the receiver's system Now Playing card.

Timed documents show previous, current and next lines. An empty timed line is an instrumental break. Before
the first timestamp the next line is visible; reaching the player duration clears the active lines. Untimed
documents use manually selected pages shared between phone and external display. Previous/Next Page on the
phone never seeks audio. Empty or unavailable documents show an explicit unavailable state; instrumental
documents show Instrumental. Missing selection shows “Choose Lyrics on This Device”. Provider errors remain
in the existing lyrics loader UI rather than becoming fabricated lyrics or timestamps.

The layout uses an opaque black background, white current text and 75% white adjacent text. Font sizes scale
with Dynamic Type and display width. A scroll view keeps lengthy phone content accessible; the external scene
has no interactive controls. Provider attribution is plain text on both surfaces, preserving the selected
document's `source`, including publisher credits. Artwork is optional and accepts only an already-loaded image
for this selection. The feature never follows `artworkURL` or makes a provider request.

## Ownership and Lifetime

| Component | Responsibility |
| --- | --- |
| `TVLyricsController` | Main-actor observable opt-in, phone presentation, selected document/variant label/artwork, manual page, track fence and external-scene activity |
| `TVLyricsTimeline` | Display projection over `LyricsDocument`/`LyricLine`; reuses `LyricsTiming` and `LRCParser.activeLineIndex` |
| `TVLyricsIdleTimer` | Captures the previous idle-timer value once per active presentation interval and restores it on release |
| `TVLyricsRuntime.shared` | Supplies the app-created controller to UIKit scenes, including scenes connected before installation |
| `TVLyricsSceneDelegate` | Retains `UIWindow(windowScene:)` and its SwiftUI hosting controller for the OS-provided scene |
| `TVLyricsPhoneLifecycle` | Reads the phone window's scene phase independently of external or CarPlay scenes |

SwiftUI reads `PlayerController.position`, `duration` and the per-track library offset through controller
closures. There is no display timer, extrapolated playback clock, second AVPlayer or replacement of player
callbacks. The controller separately observes track identity to retire old selections. A live ID check also
suppresses stale text/artwork before the observation callback runs. `synchronizeTrack()` is available for a
synchronous coordinator transition boundary. Recording IDs are compared exactly, including source prefixes.

`beginSelection(for:)` clears the prior selection and returns a token. Each model-owned load or TV restart gets
a new token; shared-loader variant choices use that load's token. `select(_:token:label:artwork:)` accepts only the latest token with
matching current-player and document track IDs. Stop, privacy reset and track changes retire pending tokens.
This is a recording fence, not an independent playback-session identity. Same-recording metadata and position
updates do not require another lyrics fetch.

Phone inactivity blanks both surfaces and releases the idle timer. Returning from Control Center can resume
the still-enabled presentation. Phone backgrounding calls `stop(reason: .suspended)`, clears the selection and
requires a new opt-in. An inactive/disconnected external scene releases its own display activity; remaining
visible surfaces keep the idle lease. Disconnect does not stop audio. Runtime replacement/uninstall stops the
old controller before releasing it.

The phone stays awake only while opted in, the phone scene is active, and either the phone page is visible or
an external scene is active. Repeated updates do not overwrite the captured idle-timer value. A previous `true`
is restored as `true`; suspension releases the lease and resuming captures the current policy anew. The app
currently has no other idle-timer owner. Future simultaneous owners will need a common lease manager rather
than competing writes. `UIApplication.shared` is used only for this public idle-timer property, never to find
screens, assign `window.screen`, enumerate deprecated screens or create an extra playback window.

## Integrated Call Sites

### 1. Retain One Controller in the App Model

The following lazy model property avoids capturing a partly initialized model. Observation of presentation
state comes from the controller itself:

```swift
@ObservationIgnored lazy var tvLyrics = TVLyricsController(
    player: player,
    lyricsOffset: { [weak self] trackID in
        self?.library.lyricsOffset(for: trackID) ?? 0
    }
)
```

`GanaBajanaApp.init` installs that same instance:

```swift
TVLyricsRuntime.shared.install(model.tvLyrics)
```

`RootView` inside `WindowGroup` has the phone lifecycle modifier beside `PhoneSceneLifecycle`:

```swift
.modifier(TVLyricsPhoneLifecycle(controller: model.tvLyrics))
```

Do not construct another `MusicAppModel` or `PlayerController` in a scene delegate. Runtime replacement and
explicit `TVLyricsRuntime.shared.uninstall()` already stop the old controller. Use the injected controller
initializer in unit hosts to keep native idle-timer calls out of model tests. One phone presentation owner is
supported; multiple simultaneously active iPad app windows need aggregate phone-phase ownership before using
this modifier on every window.

### 2. Present From the Existing Lyrics Sheet and Publish Its Chosen Document

`PlayerLyricsSheet` owns `.tvLyricsPresentation(controller: model.tvLyrics)` and `TVLyricsStartButton`.
The start button calls `model.prepareTVLyrics()`, which republishes a loaded selection after Stop or starts
the model-owned lookup. The loaded-selection branch is equivalent to:

```swift
TVLyricsStartButton(controller: model.tvLyrics) {
    guard let token = model.tvLyrics.beginSelection(for: selectedDocument.trackID) else { return }
    model.tvLyrics.select(selectedDocument, token: token,
                          label: selectedVariantLabel, artwork: nil)
}
```

`selectedDocument` and `selectedVariantLabel` denote the shared loader's current document and label.
The integrated model passes no artwork. The presentation API accepts an already-loaded matching image but
does not create an artwork request.

`loadSelectedLyrics` captures the TV token before async work. `installLyricsSelection` publishes only the
chosen result after the loader's selection fences and the model's Track/token checks. Simplified contract:

```swift
let token = model.tvLyrics.beginSelection(for: requestedTrack.id)
// Await the existing loader/variant operation here, without an additional provider request.
if let token, !Task.isCancelled {
    model.tvLyrics.select(chosenDocument, token: token, label: chosenVariantLabel)
}
```

Do not obtain a fresh token only when an old asynchronous result completes. A fresh token would authorize that
stale result again. The integrated shared loader orders same-track choices under the current load token;
restarting a load or TV presentation obtains a new token. Published variants retain their own text and timing.
No transliteration or translation is generated. The presentation API does not inspect provider internals.
Never replace `PlayerController.onSnapshotChanged` or other callbacks to drive TV timing.

`returnToLyrics()` dismisses only the phone page and is guarded by a separate scene connection. Normal Stop
and system dismissal stop all TV content. Keep the start/stop control visible in the underlying lyrics sheet
so the listener can opt out after returning to variant choices.

### 3. Privacy and Sign-Out Hooks

The model's `clearSelectedLyrics(reason:)` cancels selection work, clears the loader and stops TV. Integrated sites:

- `library.onHistoryCleared` composes TV cleanup with the existing listening, Moments and discovery resets.
- Applied history-disable preferences clear selection through the model's preference-service path, including
  accepted remote changes. Failed saves do not apply the attempted preference.
- Both Settings sign-out actions call `stopTVLyricsForSignOut()` before `account.signOut()`, including Retry.
  This stops presentation on intent even if credential deletion or intent persistence fails.

The controller observes track changes itself. The phone lifecycle modifier handles inactive/background
transitions. These are presentation/privacy operations and must not pause or rebuild the audio player.

### 4. Info.plist Scene Manifest

`project.yml` includes this role in `UIApplicationSceneManifest` alongside the existing configurations.
No scene storyboard is used. Manifest excerpt:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <true/>
    <key>UISceneConfigurations</key>
    <dict>
        <!-- Keep the existing phone and CarPlay configurations here. -->
        <key>UIWindowSceneSessionRoleExternalDisplayNonInteractive</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>TV Lyrics</string>
                <key>UISceneClassName</key>
                <string>UIWindowScene</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).TVLyricsSceneDelegate</string>
            </dict>
        </array>
    </dict>
</dict>
```

The role is `UISceneSession.Role.windowExternalDisplayNonInteractive` (iOS 16+, within the app's iOS 18 floor).
Do not add the deprecated `.windowExternalDisplay` role or claim a phone/CarPlay role for this delegate.
Preserve the existing supported interface orientations so the phone view can rotate naturally. The view does
not force global orientation or issue a device-orientation KVC write.

`BackgroundDownloadApplicationDelegate` performs scene dispatch as well as download-event reconnection.
There is one app delegate adaptor, not a separate lyrics delegate. Dispatch excerpt:

```swift
import UIKit

@MainActor
final class BackgroundDownloadApplicationDelegate: NSObject, UIApplicationDelegate {
    nonisolated override init() { super.init() }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let configuration = TVLyricsSceneConfiguration.configuration(for: session.role) {
            return configuration
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

// Inside GanaBajanaApp:
@UIApplicationDelegateAdaptor(BackgroundDownloadApplicationDelegate.self) private var appDelegate
```

The nil-name fallback reads the first matching manifest configuration for the requested role. Preserve an
existing custom dispatcher instead of replacing it with that fallback. `TVLyricsSceneDelegate` explicitly
overrides NSObject's initializer as `nonisolated`; all scene/UI callbacks remain main-actor isolated. Window
creation occurs only in `willConnectTo` with the UIKit-supplied `UIWindowScene`, not in its initializer. The
window retains its hosting controller until `sceneDidDisconnect`; runtime installation can arrive later.

`Sources/ExternalDisplay/*.swift` and `Sources/Views/TVLyricsView.swift` are app sources.
`Tests/TVLyrics*.swift` belongs to the phone unit target, not Watch or widgets.

## Bounds and Metrics

Only the current selected document, its display projection and one optional supplied image are retained.
Projection accepts at most `LRCParser.maximumLines` (5,000) timed lines and at most
`LRCParser.maximumSourceBytes` (512 KiB) each for the timed text and plain text. Untimed projection has at most
5,000 pages of 140 Swift characters, preferring a word boundary when possible. Exceeding projection bounds
shows unavailable instead of silently truncating lyrics. Invalid timestamps are excluded and equal timestamps
retain provider order. Positive timing offsets delay lyrics; the existing ±10-second `LyricsTiming` bound
applies. Projection happens on selection, not on each player tick; timed lookup is binary search.

`Logger`, subsystem `com.agraabhi.ganabajana`, category `TVLyrics`, emits only these bounded fields:

| Event | Fields |
| --- | --- |
| `presentation` | `state=started|stopped`; stops use `reason=user|privacy|signOut|suspended|runtimeReplaced` |
| `selection` | `mode=timed|untimed|instrumental|unavailable` |
| `selection_rejected` | `reason=stale_or_mismatched` |
| `external_scene` | `state=connected|disconnected` |

No per-position logs, track IDs, lyrics, variant labels, artwork URLs, receiver names, scene UUIDs or account
values are logged. There are no new network metrics because this presentation performs no network work.

## Coverage and Remaining Verification

The core suites have executed coverage in Core-03. [VERIFICATION.md](VERIFICATION.md) owns results and the
separate Integration-03/UI-02 scope. Core selectors:

```text
-only-testing:GanaBajanaTests/TVLyricsTimelineTests
-only-testing:GanaBajanaTests/TVLyricsControllerTests
-only-testing:GanaBajanaTests/TVLyricsLifecycleTests
```

| Unit suite | Cases |
| --- | --- |
| `TVLyricsTimelineTests` | Offset sign/exact boundaries, before-first/gap/end, backwards seek, nonfinite input, empty/whitespace/instrumental/unavailable documents, untimed ordering, Unicode pagination, malformed/duplicate timestamps, projection limits |
| `TVLyricsControllerTests` | Live position/duration/offset reads, immediate track/artwork fence, mismatched response and stale same-track variant, observed track reset, every stop reason and late results, shared page bounds/reset, missing current track |
| `TVLyricsLifecycleTests` | Connect without opt-in, opt-in before connect, disconnect/reconnect, inactive/background policy, last visible surface, original-true idle state, recapture after suspension, late runtime install/replacement/uninstall, native role dispatch, return to variant choices |

The lifecycle suite uses injected idle-timer storage and calls lifecycle methods directly. The role test
constructs a native configuration but does not obtain a real scene. These tests do not establish UIKit scene
delivery, visible pixels, native idle-timer behavior, receiver output or audio/video latency.

Phone light/dark presentation and source text passed UI-02. Remaining device/layout checks:

1. Phone full-screen presentation in portrait and rotated orientations, small phone/iPad dimensions, long
   lines, Dynamic Type and VoiceOver; validate Stop and untimed pages. Useful accessibility selectors are
   `tvLyrics.start`, `tvLyrics.phone`, `tvLyrics.stop`, `tvLyrics.options`, `tvLyrics.stopFromOptions`,
   `tvLyrics.currentLine`, `tvLyrics.previousLine`, `tvLyrics.nextLine`, `tvLyrics.page`,
   `tvLyrics.page.previous`, `tvLyrics.page.next`, `tvLyrics.source` and `tvLyrics.instructions`.
2. Actual Control Center Screen Mirroring: opt in, rotate, seek, change selected document and stop. Compare
   visible lyrics with audible output and record any receiver-specific delay rather than assuming alignment.
3. A connection for which iOS actually supplies the separate role: connect before/after opt-in, return to
   Lyrics Options, select another variant, page untimed lyrics, disconnect/reconnect, stop, then verify that
   backgrounding, privacy reset and sign-out leave no app-owned lyrics visible.
4. Recheck native idle-timer restoration after Stop, Control Center and backgrounding. Confirm continuing
    audio continuity while using the new presentation. Existing audio acceptance remains the owner's report.

Audio-only receivers may never expose an external scene. Screen Mirroring, receiver aspect ratio/overscan and
network buffering are system-dependent. The app cannot programmatically select a receiver, guarantee a
separate display, control its receiver-owned card or compensate for unknown audio/video latency. Very long
timed lines and extreme text sizes may exceed a noninteractive receiver's viewport; phone scrolling remains
available, and hardware layout acceptance is pending. No physical-device result is claimed for TV Lyrics.
