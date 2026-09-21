# Breezy public-page integration

**Updated and readback-verified on 21 September 2026.** Public Support and Privacy include library recovery, history-epoch/pending-listening behavior, durable alert retries, sign-out/backup details, and FFmpeg preparation/source-delivery sections. Settings copy is aligned. The source repository remains private; App Store setup and the rights hold remain open.

## Publication sources and targets

| Purpose | Local source | Public target |
| --- | --- | --- |
| Support, App Store Support URL | [SUPPORT.md](../../SUPPORT.md) | [Support Gist anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) |
| Privacy Policy, App Store Privacy Policy URL | [PRIVACY.md](../../PRIVACY.md) | [Privacy Gist anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) |
| MusicBrainz developer contact | The published Support page | [Support Gist anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md), configured in `project.yml` |
| Exact FFmpeg source/relink materials | [FFmpeg distribution record](../FFMPEG_DISTRIBUTION.md) | **TBD**; the local source bundle is repackaged and verified, but public recipient delivery remains unresolved |

The public document is [Gist 95acc71ba167fb754c435de17d256e59](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59). The source repository is private [github.com/aagrawal207/Breezy](https://github.com/aagrawal207/Breezy) on `main`, with that `origin` confirmed. Its blob/raw links are not public support/privacy endpoints.

The support contact is `aagrawal207@gmail.com`; the known public name is **Abhishek**, with copyright `2026 Abhishek`. The published pages use the email as a support/privacy contact. Apple authentication details and unresolved App Review contact fields belong outside those pages.

## Integration state

| Integration | State |
| --- | --- |
| Public page copies | Latest Support/Privacy revisions published and verified by readback on 21 September |
| Cross-links | Root `SUPPORT.md` links to the absolute Privacy anchor; root `PRIVACY.md` links to the absolute Support anchor. Preserve these published-link edits |
| Settings links | `Sources/Views/SettingsView.swift` wires **Help & feedback** and **Privacy policy** in **About Breezy** to the public anchors |
| MusicBrainz | `project.yml` supplies the Support anchor as `MusicBrainzContactURL` for the app Info.plist; `ArtistSpotlightMusicBrainz` can initialize with that contact |
| Store metadata | URL values are recorded in the local listing and IAP manifest; remote fields await creation of the App Store Connect app |
| Candidate | 1.0.0 (2) has a signed local archive and development export; [release status](RELEASE_STATUS.md) records multi-run verification and remaining acceptance |

The public URLs and page revisions are resolved. App Store Connect's 21 September readback shows working API access, web `authenticated: false` with `passwordStored: true`, and app `data: []`. App creation and web authentication remain unresolved.

## In-app copy alignment

**Aligned in source:** Settings qualifies normal backups, explains that optional sign-in cannot guarantee provider acceptance or prevent account association/logging, discloses remote exchange of provider response bodies/headers, and counts all cached versions plus preparation bytes with each song counted once.

Library-reload controls and **Sign-out pending** / **Retry sign-out** states retain their failure explanations, including retry before closing when intent cannot be saved. Real-account acceptance remains a separate open check.

The current name is provisional. [NAMING.md](NAMING.md) records the owner's pending choice; no alternative has been applied. A later selected name will need coordinated public-copy updates while retaining technical IDs and storage paths.

## After the content decision

The local policy covers network downloads, local FFmpeg packet copy, cache variants, listening recovery, pending alerts, sign-out state, and backups. A licensed-provider replacement may change those behaviors. Reconcile the pages and [App Privacy assessment](PRIVACY_REVIEW.md) with the final implementation before submission. The Gist hosts support/privacy pages; exact FFmpeg source and relinking materials still need a recipient delivery location.

Publishing a contact/policy page does not resolve the [content-rights hold](RELEASE_STATUS.md#submission-hold). URL publication status and App Store submission status are recorded separately.
