# Breezy review-question comparison

The owner requested comparison with Osho and Bruce to complete Breezy's review questions. These observations were checked on 24 September 2026 against the released apps' records, public privacy labels and local implementation documents. Each answer still has to describe Breezy's uploaded build 5.

**The partial age-rating save was rejected; no declarations changed.** Fourteen code-supported answers are prepared, with ten content descriptors awaiting assessment. Apple requires the initial questionnaire to include those fields, rather than accepting this partial save. App Privacy has since been saved in the browser as an incomplete draft (Search History, User ID and Product Interaction selected, each still marked Set Up, unpublished; [PRIVACY_DRAFT.json](PRIVACY_DRAFT.json)); the per-type purpose, linkage and tracking answers and the complete data inventory remain open. Submission remains blocked.

## Published reference apps

| App | Published age answers | Published privacy label | Content-rights field |
| --- | --- | --- | --- |
| [Osho Talks](https://apps.apple.com/us/app/id6774409039), app `6774409039` | 4+; all inspected content-frequency fields NONE and capability booleans false | Data Not Collected | `USES_THIRD_PARTY_CONTENT` |
| [Bruce](https://apps.apple.com/us/app/id6770409619), app `6770409619` | 4+; all inspected content-frequency fields NONE and capability booleans false | Health and Fitness, not linked to the user, for App Functionality | `USES_THIRD_PARTY_CONTENT` |

Osho's released app-info record is `49535561-562b-43b1-8b56-b185ca02ae41`; Bruce's is `188dac37-0d59-4e59-8277-251360009082`. Privacy labels above were read from the public App Store pages; they are not a private questionnaire export or a verification of those apps' data handling.

Read-only API comparison: `artifacts/AppStore-1.0.0-5/questionnaire-comparison-1790252213014504000/summary.json`. Public-label and authentication observations: `artifacts/AppStore-1.0.0-5/review-question-auth-20260924.json`.

Osho uses a static discourse catalog, local search, direct audio/transcript downloads and the listener's iCloud, without Google account sign-in. Bruce is a workout tracker with optional Apple Health/private CloudKit integration. Its published label differs from the current source manifest's no-collected-data array. The two apps therefore do not provide a shared privacy template for Breezy.

## Peer model check: Demus (2026-09-25)

Public sources only: the iTunes lookup/search API, the App Store web page, the developer's site and privacy page, the store screenshots, and third-party review aggregates. Nothing here is a statement from Apple or YouTube about why the app is approved.

- **Demus: Easy Music Streaming** (app `6474685600`, Simon Zvara, first released 2024-01-30, version 2.0.22 on 2026-09-08, free with Supporter subscriptions and a lifetime purchase, age rating 13+ with "Infrequent alcohol, tobacco, drug use or references" and "Contains advertising"). It sits in the US Music top-100 and reports millions of downloads.
- **Playback model as far as public evidence shows:** the store's own player screenshot carries a **YouTube** badge with a **Video | Image** toggle; the description advertises "songs & music videos"; reviews mention watching the videos, YouTube's ads during playback ("very few ads"), no downloads and no offline mode; the developer's FAQ-style third-party pages repeat "streaming only". This is consistent with the official YouTube embedded player inside the app, not with stream extraction or caching. Background play is reported as a paid-tier feature and as stopping on the free tier.
- **Why that passes Apple's gate where Breezy's model does not:** guideline 5.2.3 targets saving, converting or downloading media from third-party sources and unauthorized streaming. Playing through YouTube's own embedded player keeps YouTube's player, branding and ads intact and stores nothing, so the app can answer the third-party-content question as content accessed through the provider's sanctioned player. Breezy extracts audio streams, plays audio only in the background and caches complete songs, which is exactly the behavior 5.2.3 names.
- **Limits of the precedent:** Apple reviews against its guidelines, not against YouTube's API terms. YouTube's terms still forbid hiding the video, audio-only and background playback for embedded players, and YouTube can complain to Apple. **Musi** (app `591560124`), the best-known app with the same embedded-player model, no longer resolves in the store lookup after its 2024 removal following YouTube's complaint. Demus's Image toggle and paid background play sit on that same fault line; "on the store today" is not "authorized".
- **Privacy label for context:** Demus declares Diagnostics used for tracking, Crash Data for third-party advertising and User ID for analytics, with a generic website-template privacy policy. That is a different data model from Breezy's and not a template for its answers.

Implication for Breezy's release decision: the permitted route that peers use is the official embedded player with the video visible and no caching, which would replace the current audio-only/background/offline playback. A licensed catalog is the other permitted route.

## Confirmed Breezy age answers

[AGE_RATING_ANSWERS.json](AGE_RATING_ANSWERS.json) contains only the source-supported answers below. Apple determines the resulting age rating; the 4+ rating on the reference apps is not selected for Breezy.

| Fields | Answer | Breezy evidence |
| --- | --- | --- |
| Advertising | No | Native views/catalog presentation have no paid-ad integration or ad SDK; five StoreKit products are optional development tips |
| Gambling, simulated gambling, loot boxes and contests | No / NONE | No betting, randomized purchases or competitive-reward features; `TipJarService` grants no content or entitlement, and Recap is a private listening summary |
| Health/wellness topics and medical/treatment information | No / NONE | Music playback and mood/genre stations provide no fitness instruction, health tracking or treatment guidance |
| Messaging/chat and social media | No | No in-app messaging, public posting or social-feed interaction. Likes/follows are local library choices; `ShareLink` hands a song/recap to a separately selected app |
| Parental controls and age assurance | No | Settings has no age-verification or parent-managed content restriction. An explicit-content badge is informational, not an age gate |
| Social media disabled for under-13 users | No | No social-media/Declared Age Range integration; no age assurance mechanism |
| Unrestricted web access | Yes | `YouTubeSignInCoordinator.webView(_:decidePolicyFor:decisionHandler:)` allows navigation without a host restriction. The embedded sign-in view can follow links outside its initial page |
| User-generated content | Yes | Catalog playlist search/browsing accepts provider playlists without restricting results to developer-authored selections; user-created playlist metadata can be displayed |

Sources: `Sources/Views/YouTubeSignInView.swift`, `Sources/Catalog/YouTubeMusicService.swift`, `Sources/Catalog/CatalogParser.swift`, `Sources/Support/TipJarService.swift`, `Sources/UI/MusicComponents.swift`, `Sources/Views/RecapView.swift`, and [the provider inventory](../PROVIDERS.md).

## Content descriptors still require assessment

Ten fields remain in the partial manifest: profanity, mature/suggestive themes, sexual content, graphic sexual content, alcohol/drug references, horror, weapons and the three violence categories. The catalog preserves explicit badges and does not filter explicit recordings. Audio, lyrics, artwork and playlist metadata can carry these themes. Another app's NONE answers do not establish the frequency/intensity in this catalog.

[Apple's age-rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) include lyrics/dialogue and references, not only playable videos. A higher override alone does not complete unanswered content descriptors.

**Proposal for owner confirmation (2026-09-25).** `AGE_RATING_ANSWERS.json` now carries a complete proposed set for the ten descriptors: Infrequent/Mild for profanity, mature/suggestive themes, sexual content or nudity, alcohol/tobacco/drug references, horror/fear themes, cartoon/fantasy violence, realistic violence and weapons; NONE for graphic sexual content and prolonged graphic violence. The expected result is 12+. The public iTunes lookup API shows Spotify and Apple Music at 12+ with overlapping Infrequent/Mild descriptors and YouTube Music at 12+ with cartoon/fantasy violence only; these are context, not Breezy's assessment. Once the owner confirms the ten values, the questionnaire can be written in one request through the existing helper.

## Privacy and content-rights questions

Apple's [privacy definition](https://developer.apple.com/app-store/app-privacy-details/) distinguishes local processing from off-device collection retained beyond a real-time request. Apple-operated services and ordinary local data do not automatically become developer collection. Purpose-specific sign-in web views and integrated providers still need assessment.

Breezy sends online searches and recording interests to Google and supports a Google sign-in web view followed by account-cookie-bearing player requests. This differs from Osho's static/local search and Bruce's HealthKit data. [PRIVACY_REVIEW.md](PRIVACY_REVIEW.md) records the categories and unresolved provider retention, linkage and purposes. Neither reference app's published label establishes Breezy's answers.

Both reference apps selected `USES_THIRD_PARTY_CONTENT`. That does not grant rights to Breezy's music or extraction/caching integration. The owner confirmed those permissions are absent. The app-specific [authorization inquiry](AUTHORIZATION_REQUEST.md) remains unsent because a private recipient and applicant details are not yet established. The owner-authorized generic intake question is [posted as issue 565837697](https://issuetracker.google.com/issues/565837697), with exact title/body/account readback and New status verified after the owner completed Google's CAPTCHA. `artifacts/YouTube-authorization/intake-routing-20260924/posted.json` records the evidence. A routing question does not supply content permission; [release status](RELEASE_STATUS.md) records the remaining requirements.

The Apple API profile works. The owner renewed the expired Firefox sign-in on September 25 UTC; the target account and incomplete privacy draft were verified. Free/Paid Apps agreements, W-9 and Digital Services Act records showed Active. The separate CLI web session remains expired. `artifacts/Authorization-20260925/agreements.json` records the browser checks; passwords/session material remain in their normal stores.

## Attempt and next inputs

`artifacts/AppStore-1.0.0-5/age-rating-confirmed-1790252246811509000/` records the request, rejection and unchanged before/after declarations. The API error is: “You must provide a value for the attribute 'profanityOrCrudeHumor' with this request.” The client assertion caught that the requested values were not saved. All 24 age fields remain unanswered; the partial draft is not a successful store update.

The next write requires a complete content assessment, including the ten pending frequency/intensity values, together with the prepared capability answers. The helper refuses another partial attempt while those descriptors are missing. App Privacy requires confirmed provider handling and an authenticated Apple web session. Content rights require Breezy's own authorization or a permitted content/integration decision; the other apps' declarations do not supply it.

Final readback at `artifacts/AppStore-1.0.0-5/readback-1790252822001748000/summary.json` confirms build 5 remains VALID and attached, with matching uploaded bytes/checksum and an empty unsubmitted review container. Readiness remains 25 errors / 6 warnings. Frozen input hashes and the unchanged age declaration were checked; `review-questions-20260924.json` in the build directory records this follow-up. Osho and Bruce were read only.
