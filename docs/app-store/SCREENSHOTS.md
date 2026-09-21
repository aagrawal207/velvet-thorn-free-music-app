# Breezy screenshot plan

**Final App Store and IAP captures are pending.** Home corner changes have been screenshot-checked. The [content-rights decision](RELEASE_STATUS.md#submission-hold) determines which recordings, cover art, and lyrics may appear in release assets.

The current candidate is **1.0.0 (2)**, with a signed local archive/development export and Breezy still [provisional](NAMING.md). Leafnote is the default icon. All 72 distinct fixture UI workflows have passing coverage across the full run and follow-up, not one green full run; native StoreKit and live UI were excluded. Both separate live UI workflows have passing coverage across their initial run and recording retry. [Release status](RELEASE_STATUS.md#verification-snapshot) records the exact results; fixture coverage does not approve a marketing capture set.

## Capture and export

- Capture the real app on the approved **iPhone 17 Pro** target. Record the app version/build, iOS version, appearance, locale, and native image dimensions. Keep raw captures alongside framed exports in release artifacts.
- Use real navigable app states and authorized content. Do not paint in a song, lyric line, language classification, play count, purchase price, successful transaction, or missing control. Personal mixes and recaps should come from actual accumulated app state, not invented listening totals.
- The planned customer-facing locale is `en-US`. Use a consistent appearance for the first set; show another appearance only through an actual app capture. Clear support/account details and unrelated notifications before capturing.
- A proposed App Store export canvas is **1260 × 2736 portrait**, currently accepted in Apple's 6.9-inch group. Fit an unaltered real capture proportionally within the canvas; preserve its aspect ratio and legibility. Captions may sit outside the app image. Do not stretch a 6.3-inch capture or relabel it as evidence of another device's runtime behavior.
- Apple currently lists **1206 × 2622** and **1179 × 2556** portrait sizes for the 6.3-inch group that includes iPhone 17 Pro. Record the actual capture dimensions rather than assuming one. A 6.3-inch upload alone does not fill the required 6.9-inch or fallback 6.5-inch listing slot.
- Confirm the accepted slot/dimensions against the current store requirements at export time. The app targets iPhone; this plan does not add iPad or physical-device verification.

Source: Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), checked 20 September 2026. A valid image size is not evidence that the image or binary has been uploaded.

## Customer-facing sequence

All entries await **final capture selection and approval**. Captions are optional draft text; the screenshot must support the claim without relying on the caption.

| Order | Real app screen | Draft caption | Capture requirements |
| --- | --- | --- | --- |
| 1 | Home | Make Home yours | Recently played first, compact headings, actual populated sections, and mix text below artwork |
| 2 | Full-screen Now Playing | Keep the music close | Real recording and provider metadata; fixed transport; top More button; no added volume row or bottom Done button |
| 3 | Search > radio setup | Start with a mood | Show the station-led defaults, at least one language, and Artists (optional) with zero selected hints. Do not imply strict era filtering or guaranteed availability |
| 4 | Artist > This is [artist] | Explore an artist's songs | Available provider play counts, actual language evidence/uncertainty, and visible attribution. Do not invent monthly play totals |
| 5 | Player > Lyrics | Follow the lyrics | Use a genuinely matched recording with permission for the displayed text; retain source attribution. Show synced highlighting only when real timestamps exist |
| 6 | Library or a pushed playlist | Keep your favorites | Real saved state or the compact empty-playlist card; content clears the mini-player's intrinsic height without download/paid-access claims |
| 7 | Settings > Customize Home | Arrange your Home | Actual reorder/visibility controls and saved choices |
| 8 | Settings > App icon | Pick your Breezy | Leafnote selected as the default among 14 unique visible icons; use the actual picker and current display titles |
| 9 | Settings > Accent color | Choose your color | Real palette options and selected state; no simulated theme variants |

Song/artist examples remain TBD until the provider/content approach is settled. No availability promise for a named commercial recording is part of this plan. A personal recap image can replace a later customization image if genuine history and cleared content make it useful; it is not required to manufacture a first-launch recap.

The primary `AppIcon.png` is Leafnote. The 15 app-icon sets include its retained `AppIcon-Beat` compatibility alias and Breeze's `AppIcon-Dhol`; the extra set is not a fifteenth visible choice. Home Screen or framed icon artwork must use the selected default without implying that Leafnote is the app's name.

For **More > Audio quality**, capture actual AAC or prepared Opus source metadata, or its unavailable state. Opus is enabled on iOS 26.5+ after per-file native validation. A prepared variant may be reused later; a screenshot must not promise a Premium bitrate, lossless playback, or a whole-library upgrade.

Mini-player captures must show its real 64-point minimum, 44-point artwork, and 52-point controls, with growth at larger text sizes. Banner Retry/Dismiss targets are at least 44 points. Rotation verification used the explicit headless scene-geometry opt-in in the same app process; it is layout/keyboard evidence, not physical autorotation. The method and DEBUG-only guards are in [architecture](../ARCHITECTURE.md#verification-ownership).

Use the current Home surfaces: 4-point track/album corners, 6-point mix corners, and 10-point compact containers. Capture the actual accent foreground/background pairing and row selection states. Images do not establish native VoiceOver acceptance, which remains pending.

## IAP review-only screenshot

Use **Settings > Support development**, in **About Breezy**. Capture the actual screen after StoreKit loads all five products. The image must show:

- The explanation that tips are optional, one-time purchases and unlock no features or music.
- Small tip, Generous tip, Big tip, Grand tip, and Patron tip with the localized prices returned by StoreKit.
- Enough navigation context to identify the screen.

The same actual screen supplies review evidence for all five consumables. The file path remains `null` in [IAP_MANIFEST.json](IAP_MANIFEST.json) until an inspected capture exists. If the content requires scrolling, retain additional real captures rather than assembling fake rows into a screenshot.

Native StoreKit remains blocked by Code 3 / `notEntitled`, so this capture is pending. The local catalog stays in Debug and is excluded from Release. A Debug StoreKit image is local evidence; it does not prove App Store Connect configuration or sandbox purchases.

Apple's [IAP reference](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/) says the review screenshot is not shown on the App Store and may use any supported screenshot specification. Use the native, unframed app capture for this evidence, not a promotional icon or marketing composition.

## Current QA captures

These are raw simulator captures from completed passing tests for **1.0.0 (2)**, iPhone 17 Pro on iOS 26.5, `en-US`. The inspected Home, radio and live-player images are **1206 × 2622 pixels**. They are local QA evidence, not cleared App Store marketing assets. Each directory includes the xcresult export manifest linking files to test cases.

| Screen / state | Local artifact directory or file | Content |
| --- | --- | --- |
| Home, customization and compact empty Library | `artifacts/Breezy-QA-Home-Screenshots/` | Isolated synthetic fixture state; Home has the latest 4/6/10-point corners |
| Optional-artist radio setup | `artifacts/Breezy-QA-Radio-Screenshots/` | Isolated fixture; optional hints and cancellation workflow |
| Storage and conflict recovery | `artifacts/Breezy-QA-Storage-Screenshots/` | Passing recovery workflow captures; test errors are synthetic |
| Real full-screen player | `artifacts/Breezy-LiveUI-Review-Retry-02-Attachments/374FC3E1-075B-4694-8C25-3D8AC3BCC1BF.png` | Actual Tum Hi Ho recording, provider artwork and source metadata |
| Real synchronized lyrics and background return | `artifacts/Breezy-LiveUI-Review-Retry-02-Attachments/` | Matched LRCLIB timestamps and live playback; content-rights hold applies |

## Store capture record

For each delivered image, record raw/export paths, source version/build, capture environment, dimensions, screen state, and content source. App Store upload IDs and delivery status require remote readback. Test outcomes remain in [VERIFICATION.md](../VERIFICATION.md).
