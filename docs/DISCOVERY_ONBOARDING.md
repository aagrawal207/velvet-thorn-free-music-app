# Discovery and Onboarding

R17 is implemented and integrated. UI-01 onboarding passed; [VERIFICATION.md](VERIFICATION.md) owns counts and run boundaries. The feature UI matrix and unsigned Release checks passed; broader device/account checks remain separate.

## Optional YouTube Connection

The welcome action saves `hasCompletedWelcome` through `MusicAppModel.updatePreferences(_:)` and checks the saved value before advancing. A failed save keeps Welcome and its storage recovery controls visible.

Only that explicit welcome tap can show **Connect YouTube**. The optional step is transient `RootView` state, not a new preference or migration. Existing completed libraries, remote completion changes and relaunches do not offer it. Completion is durable before the offer, so quitting during this optional step also skips it on the next launch. An already connected account or pending sign-out skips the offer.

- **Connect YouTube** opens the existing sign-in sheet only on a tap. Closing that sheet, including Cancel or interactive dismissal, finishes onboarding.
- **Not Now** opens Home. Connection remains available in Settings > Account & Connection.
- Sign-in does not open the import page or start an import. The optional step directs listeners to **Import from YouTube Music** in Settings after signing in.
- Imports copy liked songs, playlists and followed artists only after the listener taps **Import**. They are read-only against the account. The existing import page also offers recent history and previews playlists when opened; previewing is not a library import. [ACCOUNT_IMPORT.md](ACCOUNT_IMPORT.md) owns those details.

`YouTubeConnectionCopy` in `YouTubeSignInView.swift` shares the import and playback explanations across onboarding, Settings and sign-in. Copy retains provider refusal/account association and makes no Premium audio or download-rights promise. Sign-in disclosure scrolls within a 180-point maximum so larger text remains reachable alongside the web view. New buttons have label-owned targets of at least 44 points; Connect is 56 points high. The underlying tab navigation is hidden from accessibility and touch while either onboarding page is visible.

### Identifiers

| Identifier | Purpose |
| --- | --- |
| `welcome.continue` | Existing welcome action |
| `welcome.youtube.screen` | Optional connection step |
| `welcome.youtube.connect` | Explicitly opens sign-in |
| `welcome.youtube.notNow` | Finishes without connecting |
| `signin.explanation` | Scrollable sign-in disclosure |
| `settings.youtubeImport.description` | Read-only, explicit-import explanation |
| `settings.youtubePlayback.description` | Provider acceptance and rights limits |

## Home Language Provenance

`HomeView` renders `discoveryLanguageSubtitle` in secondary caption styling before editorial discovery shelves when those shelves exist. Its identifier is `home.discovery.languages`. Current code:

```swift
private var discoveryLanguageSubtitle: String {
    let profile = model.listeningLanguageProfile
    if profile.isLearned {
        return "Languages based on your last 30 days of saved listening."
    }
    let fallback = model.library.preferences.languages
    let usesDefaults = (fallback.isEmpty || fallback == Set(MusicLanguage.allCases))
        && profile.nudges.isAutomatic
    return usesDefaults
        ? "Starting with Hindi and English. Listening shapes these shelves."
        : "Languages start from your saved settings."
}
```

`ListeningLanguageProfile.isLearned` becomes true after an identified qualified play in the 30-day summary. Likes, follows, a nonempty library and `hasListeningProfile` do not establish language learning. Cold-start legacy language settings and explicit nudges need the saved-settings branch so the subtitle does not falsely claim the default pair. Empty fallback settings use all legacy languages, currently Hindi and English. Existing shelf-specific subtitles retain their per-language provenance; this hook describes the overall language profile.

## Settings Integration

Settings > Discovery > Home and Mixes adds **Moment Mixes**, identifier `settings.moments.open`, through the existing 44-point navigation-row builder:

```swift
MomentMixesSettingsView(controller: model.momentMixes)
```

`MusicAppModel.momentMixes` supplies the same live controller used by Home. The Moments page uses shared `settingsPageChrome`, including Done; phone, SE and iPad workflows passed after that fix.

Both Settings sign-out actions, `settings.youtubeSignOut` and `settings.youtubeSignOutRetry`, call `model.stopTVLyricsForSignOut()` before `model.account.signOut()`. The integrated model hook clears the shared loader and stops TV immediately on intent, including when credential deletion or sign-out-intent persistence fails. Existing account error/retry handling determines whether sign-out succeeded.

The Downloads footer and liked-song confirmation explain that submitted transfers can continue in the background, preparation waits until returning, and force-quit stops transfers until reopening. The footer is `settings.downloads.background.description`. Production uses the integrated background session; [BACKGROUND_DOWNLOADS.md](BACKGROUND_DOWNLOADS.md) owns runtime and recovery limits. Physical OS suspension remains unverified.

## Metrics and Coverage

This UI change emits no new metrics and makes no new automatic account requests. Existing account/import diagnostics remain owned by their services.

`UITests/GanaBajanaDiscoveryOnboardingUITests.swift` covers these UI workflows against isolated, persisted fixture stores:

1. Not Now opens Home; relaunch without `--skip-welcome` does not prompt again; Settings still offers sign-in and the account remains signed out. Checks the new action target heights and absence of an automatically opened sign-in/import page.
2. Terminating at the optional step does not repeat it on relaunch.
3. A previously completed welcome loads without a connection offer, even after removing the fixture's skip flag.

UI-01 passed the onboarding workflows; counts belong in [VERIFICATION.md](VERIFICATION.md). No new unit test duplicates view state. Remaining coverage includes small-phone/iPad layouts, accessibility text, failed welcome persistence, explicit sign-in cancellation and native sign-out failure/retry. Real Google acceptance and physical background transfers require separate evidence.
