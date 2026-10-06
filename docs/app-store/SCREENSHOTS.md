# Breezy screenshots

**The iPhone and iPad galleries each show Home, Player, Album, Artist, Recap and Liked songs.** All twelve replacement images are uploaded to the editable iOS draft, delivered `COMPLETE`, and verified in order against their local MD5s. Settings, icon selection, radio setup and empty Library have been removed from those galleries. The two Watch images and five IAP review attachments retain build-3 provenance.

The new images use live provider content and actual saved listening, captured on 24 September 2026. Recap shows six counted songs, with 11 minutes on iPhone and 13 on iPad. No media, play counts or listening events were seeded. The [content-rights hold](RELEASE_STATUS.md#submission-hold) remains; draft screenshot delivery is not a rights declaration or App Review submission.

**The capture source is newer than uploaded build 5 and older than current source.** Its Debug bundle still identifies itself as `1.0.0 (5)`, but includes the post-build-5 R10 artwork backgrounds and song deduplication. It predates R11, so the Player image still shows the glass transport capsule and the heart in the title heading; current source draws the progress bar into the heart outline on one row. A matching new binary and a Player recapture are required before review. Source remains uncommitted after `ebb5d5c`. [Verification](../VERIFICATION.md#september-24-core-listening-screenshots) records capture runs; [ASC_STATE.json](ASC_STATE.json) owns remote state.

## Current listening-screen galleries

| Order | Screen | Visible state |
| --- | --- | --- |
| 1 | Home | Actual Recently played and generated mixes, with a retained mini-player |
| 2 | Player | Tum Hi Ho, its supplied Aashiqui 2 artwork and song count, paused after real playback |
| 3 | Album | Aashiqui 2, credited composers, playback actions and the attributed album description |
| 4 | Artist | Arijit Singh, provider artwork and monthly-audience wording; iPad also shows songs and collaborations |
| 5 | Recap | Actual rolling-week listening totals and top artist; iPad includes the complete metrics row and On repeat |
| 6 | Liked songs | Six songs saved through the player's Like control, with Play, Shuffle and local search |

Paths below are under `artifacts/StoreScreenshots-20260924/`:

| Device | Final images | Native dimensions | Ordered manifest |
| --- | --- | --- | --- |
| iPhone 17 Pro Max, iOS 26.5 | `capture-01/iphone17promax/final/` | 1320 × 2868 | `readback-1790286580768511000/iphone-assets.json` |
| iPad Pro 13, iOS 26.5 | `capture-05/ipadpro13/final/` | 2064 × 2752 | `readback-1790286580768511000/ipad-assets.json` |

Each device directory retains `raw/` captures and per-image `metadata/`. The aggregate manifests record file paths, observed recording IDs, actual simulator and library identifiers, capture times, hashes and remote asset IDs. All twelve final images were visually inspected. The readback also verifies identical raw/final RGB pixels and ICC profiles, opaque final PNGs, exact remote order and `COMPLETE` delivery. `previous-store/` preserves downloaded copies of the replaced gallery; build-3/build-4 source assets remain frozen.

Capture and upload operations used `asc` 5.3.4. The local capture route is `asc xcode test` with the opt-in `test10CoreListeningScreens`; `test11ResumeCoreListeningScreens` can recapture an existing isolated listening session without adding history. The iPad set comes entirely from the passing resume run after an interrupted initial run and capture-navigation corrections. [Verification](../VERIFICATION.md#september-24-core-listening-screenshots) preserves those boundaries.

## September 25 recapture from current source (local only)

`artifacts/StoreScreenshots-20260925/capture-01/` holds a complete replacement set captured from the current working tree (Debug bundle `1.0.0 (6)`, iOS 26.5) with `test11ResumeCoreListeningScreens`, which reopened the two isolated live listening sessions from September 24 without adding history: `store-capture-A2DCB4A5-3D9D-471C-8409-A8657C9285CB` on the iPhone 17 Pro Max simulator and `store-capture-BF67A612-0C74-4B11-9062-AB3C7CFA5870` on the iPad Pro 13 simulator. Both runs passed (`R11-CoreScreens-iphone17promax-0925-01.xcresult`, `R11-CoreScreens-ipadpro13-0925-01.xcresult`). The twelve final images keep the native dimensions (1320 × 2868 and 2064 × 2752), opaque RGB conversion and per-image metadata, now marking the R11 source state. All twelve were inspected on a contact sheet; the Player shows the container-free transport and the progress-to-heart row with the same six live recordings.

`capture-02/` repeats the same two live sessions after the owner's review adjustments (heart raised on the line, translucent liked fill) and supersedes `capture-01/` for any upload. **Nothing was uploaded.** The remote galleries still hold the September 24 set. Replacing them is one guarded publication run once the owner decides to deliver a matching binary; if the provider decision changes the player, this set is superseded too.

Both local capture sets under `artifacts/StoreScreenshots-20260925/` predate R13's player changes (heart back in the heading, full-width progress bar, resized AirPlay glyph, swipe up) and the R12 shell; their Player image shows the retired progress-to-heart trail. No recapture is planned under the local-only decision ([ROADMAP.md](../ROADMAP.md)).

## Historical build-4 screenshots

`artifacts/AppStore-1.0.0-4/iphone-final/` and `ipad-final/` contain the refreshed images; `iphone-assets.json` and `ipad-assets.json` record source build, device, raw attachment and checksums. The order is Search/library shortcuts, language-free radio setup, app icons, Customize Home, iCloud waiting and empty Library. Native dimensions, RGB pixels and ICC profiles are preserved. All twelve final images were inspected.

Six phone capture workflows passed. Five iPad workflows passed in the main run; Customize Home passed its focused rerun after the helper revealed the virtualized Reset row. The iPad manifest incorporates that replacement capture. These are unseeded real-app states, distinct from R8 widget fixtures. Build-5 readback at `artifacts/AppStore-1.0.0-5/readback-1790220802087226000/screenshots.json` verifies all 14 ordered remote MD5s and COMPLETE delivery, including the retained Watch pair. The build-4 delivery receipt remains historical.

## Historical build-3 set

All paths below are under `artifacts/AppStore-1.0.0-3/`. Each manifest records the raw attachment, device ID, test, time, version/build, dimensions and file hashes. Conversion removed only an entirely opaque alpha channel, preserving dimensions, RGB pixels and the ICC profile. No framing, resizing or painted controls were added.

| Device | Final images / manifest | Dimensions | Remote set |
| --- | --- | --- | --- |
| iPhone 17 Pro Max, iOS 26.5 | `iphone-final/`, `iphone-assets.json`, 6 images | 1320 × 2868 | `d9872aa7-edc0-4270-838e-67e4c6612f11`, `APP_IPHONE_67` via asc `IPHONE_69` |
| iPad Pro 13, iOS 26.5 | `ipad-framed-final/`, `ipad-framed-assets.json`, 6 images | 2064 × 2752 | `04f98da0-1649-4069-9642-2d341cacdc20`, `APP_IPAD_PRO_3GEN_129` |
| Watch SE 3 44 mm, watchOS 26.5 | `watch-final/`, `watch-assets.json`, 2 images | 368 × 448 | `9df6d109-2f9b-4a19-9d47-2d66b38b516a`, `APP_WATCH_SERIES_4` |

Phone and iPad order is Search/radio, radio setup, original app icons, Customize Home, enabled iCloud waiting state, and empty Library. The iPad's first two images were recaptured at the top of Search to avoid a clipped suggestion row; `ipad-radio.xcresult` and `ipad-radio-raw/` preserve that correction. The other four images retain their first-run provenance. Every final image was inspected; all 14 remote images report `COMPLETE`, and their ordered MD5s match the local manifests.

The Watch images show an empty player confirmed by the real paired phone and the actual Library folders. They use real WatchConnectivity, without a Watch transport fixture. The raw helper's historical attachment prefix says 40 mm; the device ID, 368 × 448 pixels and provenance establish the 44 mm capture. The helper label is corrected for future runs. Raw files and manifests remain intact.

The phone/iPad library is isolated by the UI-test host, with no seeded media or history. Native iCloud activation is disabled there, so the cloud image shows the actual enabled waiting state and no success time. This is interface evidence, not two-device delivery. Native StoreKit supplied the IAP screen on an iOS 27 simulator, as recorded below.

## Historical implementation captures

R5 QA captures are in `artifacts/R5-iPhone-Captures/`, `artifacts/R5-BrowseRetry-Captures/` and `artifacts/R5-iPad-Captures/`, with export manifests. They show the enabled/disabled cloud indicator, reorganized Settings, combined album/artist chooser, native AirPlay button and smaller artist header. The corrected largest-text landscape workflow passed with actual artist selection. Original bundled icon artwork is used as an explicit test fixture. These captures do not establish native cloud delivery, receiver connectivity or marketing-content clearance.

`artifacts/R5-Live-Search-PlayCounts.png` separately records a real-catalog Search for Tum Hi Ho, with `1.2B plays` on the returned Arijit Singh recordings. It uses provider content and remains QA evidence under the content-rights hold; it is not in the delivered store set.

The earlier captures below use isolated fixture content. The Watch images come from Watch SE 3 40 mm on watchOS 26.5; phone images come from iPhone 17 Pro on iOS 26.5. Current iPad captures are listed above. Mac runtime captures remain pending.

| State | Local artifact |
| --- | --- |
| Sonnet rebuilt on the Thorn rose (current two-rose set) | `artifacts/rose-pen-sonnet-contact-sheet.png` |
| Reversed pen directions (historical three-rose set including Copper) | `artifacts/rose-pen-reversed-contact-sheet.png` |
| Mini-player half progress, dark | `artifacts/Breezy-Phone-Experience-UI-01-Captures/7FC8DEE4-A8B1-41EF-9739-26AF08A75D2D.png` |
| Mini-player half progress, largest-text light | `artifacts/Breezy-Phone-Experience-UI-01-Captures/2CB1F914-835E-45AF-8D81-6D636FDBC085.png` |
| Attributed album preview | `artifacts/Breezy-Phone-Experience-UI-01-Captures/2BA472A5-5A87-4257-95AB-A8D01EC297F2.png` |
| Watch transport on the first screen | `artifacts/Breezy-Watch-UI-Fixes-02-Captures/2E47547A-D449-4F75-B09D-B1BD01EAEB1F.png` |
| Long Watch song row, fully reachable | `artifacts/Breezy-Watch-UI-Fixes-02-Captures/F5BBC8A4-34A9-455F-A5A2-87AF9E18064E.png` |
| Real paired-simulator Watch Connectivity | `artifacts/Breezy-Watch-Connectivity-02-Captures/` |

Each capture directory has an export manifest. Native CarPlay head-unit screenshots remain pending capability/profile approval and device verification. The Sonnet rose now shares Thorn's composition in a cream and mauve palette; earlier Sonnet and Copper artwork is historical. Earlier rose artwork below shows the original pen direction and is retained as historical evidence.

The **historical reference baseline** has passing coverage for 72 distinct fixture UI workflows across the full run and follow-up, not one green full run; native StoreKit and live UI were excluded. Both separate live UI workflows have passing coverage across their initial run and recording retry. [Release status](RELEASE_STATUS.md) records those historical results and the current refinement results separately; verification does not approve a marketing capture set.

## Capture and export

- Capture the real app on owned **iPhone 17 Pro Max** and **iPad Pro 13-inch (M4)** simulators for the largest required slots. Record version/build, OS, appearance, locale and native dimensions. Keep raw captures and export manifests. Use device suffixes to avoid mixing phone/iPad assets.
- Use real navigable app states and authorized content. Do not paint in a song, lyric line, language classification, play count, purchase price, successful transaction, or missing control. Personal mixes and recaps should come from actual accumulated app state, not invented listening totals.
- The planned customer-facing locale is `en-US`. Use a consistent appearance for the first set; show another appearance only through an actual app capture. Clear support/account details and unrelated notifications before capturing.
- The delivered phone images are native **1320 × 2868** portraits. `asc screenshots validate --device-type IPHONE_69` maps them to API type `APP_IPHONE_67`. Do not resize a smaller-device capture or relabel its runtime evidence.
- Apple currently lists **1206 × 2622** and **1179 × 2556** portrait sizes for the 6.3-inch group that includes iPhone 17 Pro. Record the actual capture dimensions rather than assuming one. A 6.3-inch upload alone does not fill the required 6.9-inch or fallback 6.5-inch listing slot.
- The app now supports iPad, so iPad screenshots are required. Capture on iPad Pro 13-inch (M4) for Apple's 13-inch group (for example 2064 × 2752 or 2048 × 2732 portrait) and record the actual dimensions. Show the regular-width layout: the 1000-point content column, edge-to-edge Home carousels, the centered 640-point mini-player, and the top tab bar. Mac (Designed for iPad) needs no separate screenshot set.
- Confirm the accepted slots/dimensions for both device groups against the current store requirements at export time. This plan does not add physical-device verification.

Source: Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), checked 20 September 2026. A valid image size is not evidence that the image or binary has been uploaded.

## Historical media-led proposal, superseded

The owner replaced this earlier proposal with the six listening screens above. The table is historical, including its outdated radio language controls. Content authorization remains required before public release. Captions below were draft text, not painted app controls.

| Order | Real app screen | Draft caption | Capture requirements |
| --- | --- | --- | --- |
| 1 | Home | Make Home yours | Recently played first, compact headings, actual populated sections, and mix text below artwork |
| 2 | Full-screen Now Playing | Keep the music close | Real recording and provider metadata; fixed previous, play, and next transport; top More button; no added volume row or bottom Done button. Shuffle and Repeat belong to the Queue sheet, not this screen |
| 3 | Search > radio setup | Start with a mood | Show the Moods/Genres station grid or the station-led setup defaults, compact language switches with at least one selected language, and Artists (optional) with zero selected hints. Any station works in any chosen language; do not imply strict era filtering or guaranteed availability |
| 4 | Artist > This is [artist] | Explore an artist's songs | Capture the default popular-song list with its collapsed Languages control and available provider counts. An expanded language-browser capture must show real evidence; Browse by language requires at least two identified languages. Do not invent monthly play totals or language results |
| 5 | Player > Lyrics | Follow the lyrics | Use a genuinely matched recording with permission for the displayed text; retain source attribution. Show synced highlighting only when real timestamps exist |
| 6 | Library or a pushed playlist | Keep your favorites | Real saved state or the compact empty-playlist card; content clears the mini-player's intrinsic height without download/paid-access claims |
| 7 | Settings > Customize Home | Arrange your Home | Actual reorder/visibility controls, compact native-switch visuals, and saved choices |
| 8 | Settings > App icon | Pick your Breezy | Leafnote selected as the default among 7 unique visible icons, including Thorn and Sonnet; use the actual picker and current display titles. iPhone/iPad only: the row is hidden on a Mac running the iPad app |
| 9 | Settings > Accent color | Choose your color | Real palette options and selected state; no simulated theme variants |

Song/artist examples remain TBD until the provider/content approach is settled. No availability promise for a named commercial recording is part of this plan. A personal recap image can replace a later customization image if genuine history and cleared content make it useful; it is not required to manufacture a first-launch recap.

The primary `AppIcon.png` is Leafnote. The 8 app-icon sets include its retained `AppIcon-Beat` compatibility alias; the alias is not an eighth visible choice. Thorn and Sonnet are original pen-piercing-rose designs inspired by the supplied visual reference, not copies of its branding; they share one composition in two palettes. Their generated assets are 1024 × 1024 icon PNGs and 240 × 240 picker-preview PNGs, all RGB without alpha. The [rose-pen contact sheet](../../artifacts/rose-pen-sonnet-contact-sheet.png) is generated artwork, not an app screenshot. One historical icon-selection workflow in `Breezy-Refinements-UI-01` covered the earlier three rose selections, persistence, and restoration of Leafnote; the two-rose rerun is pending. Home Screen or framed icon artwork must use the selected default without implying that Leafnote is the app's name.

For **More > Audio quality**, capture actual AAC or prepared Opus source metadata, or its unavailable state. Opus is enabled on iOS 26.5+ after per-file native validation. A prepared variant may be reused later; a screenshot must not promise a Premium bitrate, lossless playback, or a whole-library upgrade.

Mini-player captures must show its real 64-point minimum, 44-point artwork, and 52-point controls, with growth at larger text sizes; on iPad the capsule is capped at 640 points and centered. Banner Retry/Dismiss targets are at least 44 points. Rotation verification used the explicit headless scene-geometry opt-in in the same app process; it is layout/keyboard evidence, not physical autorotation. The method and DEBUG-only guards are in [architecture](../ARCHITECTURE.md#verification-ownership).

Use the current Home surfaces: 4-point track/album corners, 6-point mix corners, and 10-point compact containers. Capture the actual accent foreground/background pairing and row selection states. Images do not establish native VoiceOver acceptance, which remains pending.

Compact switches use a 20% smaller native visual at 0.8 scale while the button row retains a 44-point minimum tap height and a native Toggle accessibility representation. The style is explicit at all four Toggle call sites in Settings, Discovery languages, Customize Home, and radio setup, not global on RootView. **All four compact-switch workflows passed in `Breezy-Compact-Switch-03`**, including radio. The helper taps a native child only when reachable, otherwise the visible parent row; native state, persistence, disabled-selection, and reorder assertions remain required despite zero-bounds virtual children.

Returning to the app from the background shows the screen the listener left; there is no automatic full-player presentation to capture. Two spotlight workflows and the separate language-correction workflow passed in `Breezy-Refinements-UI-01`. The four live language cases also passed, but named recording availability and catalog-wide accuracy are not screenshot claims.

## IAP review-only screenshot

Use **Settings > Support development**, in **About Breezy**. Capture the actual screen after StoreKit loads all five products. The image must show:

- The explanation that tips are optional, one-time purchases and unlock no features or music.
- Small tip, Generous tip, Big tip, Grand tip, and Patron tip with the localized prices returned by StoreKit.
- Enough navigation context to identify the screen.

The inspected file is `artifacts/AppStore-1.0.0-3/iap-final/90-iap-native-products-en-US-iphone17promax.png`, 1320 × 2868, MD5 `b27724649e553540dcc9c48e87be7ae6`. It shows all five actual product names, descriptions, USA prices and the optional-tip explanation without scrolling. All five review attachments report `COMPLETE` with that checksum; [IAP_MANIFEST.json](IAP_MANIFEST.json) records their IDs.

`iap-shots-ios27-02.xcresult` passed the native product-display workflow on iOS 27. StoreKit configuration/override diagnostics remain in its log; no purchase was made, and the earlier iOS 26.5 native transaction-suite failure remains historical. The local catalog stays in Debug and is excluded from Release. Separate API receipts verify the five configured products; this image does not establish sandbox transaction success.

Apple's [IAP reference](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/) says the review screenshot is not shown on the App Store and may use any supported screenshot specification. Use the native, unframed app capture for this evidence, not a promotional icon or marketing composition.

## Reference-baseline QA captures

These are raw simulator captures from completed passing tests for the earlier **1.0.0 (2)** reference baseline, iPhone 17 Pro on iOS 26.5, `en-US`. They predate the post-`ebb5d5c` icon, switch, language-browser, radio, player, and iPad/Mac refinements. The inspected Home, radio and live-player images are **1206 × 2622 pixels**. They are local QA evidence, not cleared App Store marketing assets. Each directory includes the xcresult export manifest linking files to test cases.

| Screen / state | Local artifact directory or file | Content |
| --- | --- | --- |
| Home, customization and compact empty Library | `artifacts/Breezy-QA-Home-Screenshots/` | Isolated synthetic fixture state; reference-baseline Home has 4/6/10-point corners |
| Optional-artist radio setup | `artifacts/Breezy-QA-Radio-Screenshots/` | Isolated fixture; optional hints and cancellation workflow |
| Storage and conflict recovery | `artifacts/Breezy-QA-Storage-Screenshots/` | Passing recovery workflow captures; test errors are synthetic |
| Real full-screen player | `artifacts/Breezy-LiveUI-Review-Retry-02-Attachments/374FC3E1-075B-4694-8C25-3D8AC3BCC1BF.png` | Actual Tum Hi Ho recording, provider artwork and source metadata |
| Real synchronized lyrics and background/reactivation playback | `artifacts/Breezy-LiveUI-Review-Retry-02-Attachments/` | Matched LRCLIB timestamps and live playback continuing across a background/reactivation cycle; content-rights hold applies |

## Store capture record

For each delivered image, record raw/export paths, source version/build, capture environment, dimensions, screen state, and content source. App Store upload IDs and delivery status require remote readback. Test outcomes remain in [VERIFICATION.md](../VERIFICATION.md).
