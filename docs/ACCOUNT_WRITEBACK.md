# YouTube Account Write-Back

R18 is implemented and integrated with the model, Settings and Player More. Core/regression tests and light/dark account workflows on phone, SE and iPad passed, including cancellation before confirmation and unchanged local likes. [VERIFICATION.md](VERIFICATION.md) owns counts and receipts. Tests sent no real user-account activity to YouTube; provider acceptance remains unknown.

## Behaviour

**Allow YouTube Changes** starts off. The listener enables it for the current sign-in on this device and then confirms each remote action. Available actions are **Like on YouTube**, **Remove YouTube Like**, **Add to YouTube Playlist**, **Subscribe on YouTube** and **Unsubscribe on YouTube**. An existing local heart, playlist edit, follow, import or iCloud merge never calls this controller.

The page explains that Google can see the requests and may refuse this unofficial connection. It uses the default Google account (`X-Goog-AuthUser: 0`). Multiple-account and brand-account selection are unsupported. Before enabling, the listener must reconnect the intended default account. The cookie bridge does not supply a verified account name or brand-account selector; the page does not invent either.

Song actions require a bare, valid 11-character YouTube recording ID. A JioSaavn or Gaana track is ineligible even if playback found a YouTube fallback. Subscription actions require a linked, exact `UC` channel ID with 24 ASCII identifier characters. Name-only credits, `MPAD` browse IDs and `MPLAUC` library wrappers are not converted or resolved for writes. The page offers each eligible credited artist separately, without deriving subscription state from local follows.

Playlist loading is manual. The page offers only `VLPL…` collections with a matching playlist-editor ownership marker in the account response. Selecting a row does not write. The listener confirms Add after choosing the playlist. The controller requires a selection from its current account/context listing, no older than five minutes; the client then rechecks the selected playlist's editable header immediately before the add. Saved foreign playlists, system playlists, mixes and collections without that evidence are unavailable. The shared `MusicCollection` is the only playlist model.

Mutations have one active slot. The controller reserves it synchronously on the tap; overlapping taps are dropped rather than queued. Sign-out, replacement sign-in, disable, cancellation and page retirement invalidate the context, clear playlist selections and cancel in-flight work. Late completions cannot update a newer page. Cancellation after submission cannot undo a change Google may already have accepted, so a pending mutation reports **Could not confirm the YouTube change. Check YouTube Music before trying again.**

## Public Protocol Sources

Research pinned `sigma67/ytmusicapi` to commit [`bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc`](https://github.com/sigma67/ytmusicapi/commit/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc). These sources establish request shapes; they do not establish that Velvet Thorn's cookies or client are accepted.

| Source | Contract used |
| --- | --- |
| [Browser authentication documentation](https://ytmusicapi.readthedocs.io/en/stable/setup/browser.html), [`auth/browser.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/auth/browser.py) | Browser cookies, `X-Goog-AuthUser`, origin and native header authentication |
| [`helpers.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/helpers.py), [`ytmusic.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/ytmusic.py) | WEB_REMIX context; a fresh `SAPISIDHASH <unix-seconds>_<sha1(seconds + " " + cookie + " " + origin)>` on each request; browser auth prefers `__Secure-3PAPISID` |
| [`mixins/library.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/mixins/library.py), [`mixins/_utils.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/mixins/_utils.py) | Like/remove-like and single-channel subscription endpoints; a `showEngagementPanelEndpoint` can be a gated HTTP 200 rather than a completed write |
| [`mixins/playlists.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/mixins/playlists.py) | `browse/edit_playlist`, `ACTION_ADD_VIDEO`, unprefixed playlist ID, success status and per-video result; editable playlist header ownership |
| [`parsers/browsing.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/parsers/browsing.py), [`navigation.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/navigation.py) | `owned` requires `menuNavigationItemRenderer.navigationEndpoint.playlistEditorEndpoint.playlistId` matching the row; exact editable-header path |
| [`mixins/watch.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/mixins/watch.py), [`parsers/watch.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/parsers/watch.py), [`parsers/songs.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/parsers/songs.py) | Read-only `next` request and exact recording's like-menu state. An available INDIFFERENT action means currently liked; a LIKE action means currently not liked. That latter state can include dislike. |
| [`tests/mixins/test_library.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/tests/mixins/test_library.py), [`tests/mixins/test_playlists.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/tests/mixins/test_playlists.py) | Upstream like tests assert only `actions`; playlist tests assert success and edit results. A generic nonempty response is insufficient evidence for this implementation. |

The exact subscription receipt fields come from YouTube.js [`UpdateSubscribeButtonAction.ts`](https://github.com/LuanRT/YouTube.js/blob/bad89d2657e88f907011655f199fba9fb615c339/src/parser/classes/actions/UpdateSubscribeButtonAction.ts), pinned to commit [`bad89d2657e88f907011655f199fba9fb615c339`](https://github.com/LuanRT/YouTube.js/commit/bad89d2657e88f907011655f199fba9fb615c339): `channelId` and boolean `subscribed`. Whether WEB_REMIX returns that receipt for the owner's account has not been observed.

The fixed `prettyPrint=false&alt=json` query follows YouTube.js [`HTTPClient.ts`](https://github.com/LuanRT/YouTube.js/blob/bad89d2657e88f907011655f199fba9fb615c339/src/utils/HTTPClient.ts), which does not append an API key. This differs from ytmusicapi's browser-specific public-key query in [`constants.py`](https://github.com/sigma67/ytmusicapi/blob/bf310f7fc6041a51db229fd9d8ee96fa45c2cdbc/ytmusicapi/constants.py); no private Data API key is reused for account writes.

## Requests and Confirmation

All authenticated requests are native `URLSession` POSTs to `https://music.youtube.com/youtubei/v1/<endpoint>?prettyPrint=false&alt=json`.

| Action | Endpoint and body beyond context | Confirmation required |
| --- | --- | --- |
| Like | `like/like`, `target.videoId` | Nonempty mutation `actions`, followed by one fresh authenticated `next` read of the exact ID showing liked |
| Remove like | `like/removelike`, `target.videoId` | Same read showing not liked; no claim about a local heart or a previous dislike |
| Add | `browse/edit_playlist`, `playlistId` without `VL`, one `actions` item with `action: ACTION_ADD_VIDEO`, `addedVideoId` | Exact `STATUS_SUCCEEDED`, exactly one `playlistEditVideoAddedResultData` with the requested `videoId` and a nonempty bounded `setVideoId` |
| Subscribe / unsubscribe | `subscription/subscribe` / `subscription/unsubscribe`, one-element `channelIds` | `actions[].updateSubscribeButtonAction` matching the exact channel and desired boolean; contradictory updates fail |
| Owned playlist list | `browse`, `browseId: FEmusic_liked_playlists`; subsequent body `continuation` | Grid shape and row-level editor evidence |
| Ownership preflight | `browse`, selected `browseId: VLPL…` | `contents.twoColumnBrowseResultsRenderer.tabs[].tabRenderer.content.sectionListRenderer.contents[].musicEditablePlaylistDetailHeaderRenderer.playlistId` matches the unprefixed selection |
| Like-state read | `next`, `videoId`, `playlistId: RDAMVM<videoId>`, `enablePersistentPlaylistPanel: true`, `isAudioOnly: true`, `tunerSettingValue: AUTOMIX_SETTING_NORMAL`, `watchEndpointMusicSupportedConfigs.musicVideoType` under `watchEndpointMusicConfig` | Exact playlist-panel row, matching like target, consistent known state and explicit signed-in response evidence |

The next request's `watchEndpointMusicConfig` includes `hasPersistentPlaylistPanel: true` and `musicVideoType: MUSIC_VIDEO_TYPE_ATV`, matching the upstream request. The response must explicitly report `responseContext.mainAppWebResponseContext.loggedOut: false` or `responseContext.serviceTrackingParams` with GFEEDBACK `logged_in: "1"`. Missing evidence returns unknown. These are conservative response acceptance conditions, not a claim that every accepted YouTube client receives these fields.

Empty, malformed or unknown responses, unknown/wrong-typed status, gated dialogs, missing receipts and failed verification produce **Could not confirm**. A generic HTTP 200 or toast never suffices. Confirmation means the provider acknowledged the target or a fresh account read observed the requested state, not that an earlier state was different. HTTP 401/403 and authentication error envelopes require reconnecting. HTTP 429 applies `Retry-After` or a 30-second default cooldown. HTTP 400/404 reports rejection. Transport loss, cancellation and 5xx are uncertain. No mutation POST is automatically retried, including timeout, connection loss and 5xx; no offline queue or reconnect replay exists. A later attempt requires another explicit confirmation.

## Authentication, Storage and Bounds

- Existing cookies remain in `YouTubeAccountStore`'s after-first-unlock, ThisDeviceOnly Keychain session. The new client never writes cookies, signed URLs or provider responses to a file, library, log, sync replica, widget or companion.
- A new optional `YouTubeAccountSession.writeSessionID` is a random UUID created at sign-in and saved with the existing session. Legacy sessions decode with nil and keep playback/import compatibility; reconnecting is required before enabling writes. Each sign-in gets a fresh binding, even for the same cookies or clock value.
- `YouTubeAccountWritePermissionStore` keeps one credential-free JSON record under service `com.agraabhi.ganabajana.youtube-write-permission`, key `permission`, using the existing `KeychainSecretStore`. It contains version 1, strict boolean `allow`, optional `sessionID` and random `generation`. The Keychain item is ThisDeviceOnly and is not iCloud-synchronizable. A missing item means off. Replacement uses atomic `SecItemUpdate`; every permission edit changes generation. This is separate from `UserPreferences` and `LibraryStore`.
- Permission reads are capped at 4 KiB. Corrupt, wrong-typed or future-version data and externally changed records fail closed and are preserved. Writes compare the last-read bytes before replacing the record. One model-owned controller is required. Concurrent application processes are not supported as permission writers. A failed disable immediately cancels requests and disables this controller, with a visible retry-before-closing error. Until that retry succeeds, an older enabled record may remain durable; the UI must retain the error.
- Device migration cannot carry the ThisDeviceOnly permission. A replacement account session cannot use a previous sign-in's permission. Settings does not propagate the switch through iCloud.
- Music write auth accepts only `.youtube.com`, `.music.youtube.com` or host-only `music.youtube.com` cookies applicable to the exact request path and current time. Unrelated YouTube hosts and expired/path-mismatched cookies are excluded. Duplicate cookie names, header delimiters/control characters, excessive cookies or missing usable authentication fail closed. The header is capped at 16 KiB / 128 cookies.
- The transport signs with `__Secure-3PAPISID` when present, otherwise the existing SAPISID path, using current whole Unix seconds and fixed music origin. A 1P-only session is insufficient. The signing algorithm has no random nonce; no nonce is invented. Random UUIDs are used for sign-in, permission and operation identity, not inserted into the hash. Authorization is rebuilt per request and never cached separately.
- Headers include native `Cookie`, `Authorization`, fixed `Origin`, `X-Origin`, `Referer`, `X-Goog-AuthUser: 0`, `X-Youtube-Bootstrap-Logged-In: true`, browser User-Agent, JSON content type and WEB_REMIX client headers. The version comes from the existing anonymous `WebRemixConfiguration` bootstrap/fallback. Catalog transport receives no account headers.
- URL validation fixes HTTPS, exact host, endpoint allowlist and query. Userinfo, explicit ports, fragments and encoded/foreign paths are refused. Every redirect, including same-host 307/308, is declined before credentials or the POST body can follow. The response URL must equal the requested URL. Server trust uses native validation; HTTP authentication challenges are cancelled; credential storage, cookies and URL cache are disabled. Additional body-stream replay requests are refused.
- A per-task delegate applies the 2 MiB inclusive response cap on declared length and each received chunk. Request timeout is 15 seconds and the ephemeral session resource timeout is 20 seconds; one host connection and one client operation are allowed. `waitsForConnectivity` is false. Task resume and access revocation share a lock, so a retired access cannot submit the next request. Request cancellation cancels only that operation.
- Owned-playlist listing has at most 10 pages and 200 returned collections. Repeated continuation tokens fail; tokens are capped at 64 KiB. No new page starts after 90 seconds; a previously admitted request can take its remaining resource timeout. Reaching a page/count cap explicitly labels the list limited. In-memory selection evidence expires after five minutes and is cleared on retirement.

The import actor's private browse transport cannot supply raw ownership markers, and its collection-only protocol loses those markers. The new adapter therefore reuses `CatalogParser.browse`, `CatalogJSON`, `CatalogText`, `YouTubeAccountLibraryParser.playlists/gridContinuation`, `YouTubeLibraryPage` and `MusicCollection` under a stricter transport. It does not duplicate the import worker or alter its read-only semantics.

## Integrated App APIs

`MusicAppModel.youTubeWrite` retains one observable `YouTubeAccountWriteController`, sharing the model's account and known-offline state. Its optional initializer injection supports fixtures; non-device hosts use a memory permission store. Construction and rendering make no authenticated request. Model teardown calls `shutdown()` to remove the account observer.

Settings > Account & Connection > **YouTube Changes** (`settings.youtubeChanges`) presents the shared controller and current context, including while signed out. Its `onDone` closes the whole Settings sheet. Player More offers `player.options.youtubeChanges` only for an eligible YouTube track. The tap captures the displayed track and controller context; `.youtubeChanges` presents that immutable selection rather than substituting the next playing song. The view lists eligible linked channel credits and owns each confirmation dialog.

Player More passes `showsDoneButton: false`: its parent owns the single `player.options.toolbarDone` control. Settings uses the default `true` and keeps `youtubeWrite.done`. The toolbar fix adds no metrics; the light/dark account UI workflow asserts exactly one Done in the player and exercises Settings dismissal.

| API | Contract |
| --- | --- |
| `setAllowsChanges(_:)` | Explicit device/sign-in permission change; creates a new context |
| `perform(_:track:playlist:context:)` | Confirmed like, remove-like or add-to-playlist for the captured target/context |
| `loadOwnedPlaylists(context:)` | Manual read-only listing with current-context ownership evidence |
| `setSubscribed(_:artist:context:)` | Confirmed subscription change for an exact linked channel |
| `cancel()`, `shutdown()` | Retire work; shutdown also removes the account observer |
| `isBusy`, `isLoadingPlaylists`, `message`, `permissionError`, `allowsChanges`, `playlistsAreLimited` | Observable presentation state |

`YouTubeAccountWriteView` updates its context after same-session permission changes, dismisses pending confirmations and clears playlist selection. A session revision change leaves the old page stale until reopened. Leaving a current page calls `cancel()`. Sign-out and session replacement synchronously revoke access through account-store observation. Local heart/follow/playlist edits, import and cloud callbacks never call mutation APIs.

## Metrics

OSLog, subsystem `com.agraabhi.ganabajana`, category `Account`. No cookie, hash, account binding, recording/channel/playlist ID, title, response, exception text or URL is logged.

| Event | Emitted when | Bounded fields | Purpose |
| --- | --- | --- | --- |
| `account_write_permission` | Enable/disable persisted, or permission storage refused | `enabled=true/false`, or `status=storage_error` | Distinguish permission state from provider errors |
| `account_write` | Mutation starts, confirms, fails, is refused before transport or retires | `action=like/removeLike/addToPlaylist/subscribe/unsubscribe/playlists/pending`; `status=started/confirmed/retired` or `YouTubeAccountWriteError` raw value | Show uncertainty and guard outcomes without account data |
| `account_write_playlists` | Owned-list fetch completes | `status=ok`, count 0…200 | Establish a completed listing, including empty |

## Test Coverage

The table maps coverage included in the coordinator's targeted core/regression work. [VERIFICATION.md](VERIFICATION.md) owns execution results. Fixtures are hand-written from the pinned public schemas, not captured from the owner's account.

| Case / test | Branch or path | Unit or integration |
| --- | --- | --- |
| `testRequestShapesForAllFiveExplicitActions` | Method, endpoint/body, context, fixed headers and hash input | Unit |
| `testHostPathSchemePortAndUserInfoGuardStripsSecrets` | Foreign host/scheme/endpoint, userinfo, port, encoded path, extra query, fragment | Unit |
| `testScopedCookiesExpiryInjectionAndFresh3PHash` | Scoped cookie selection, expiration/path, header injection, 3P preference and fresh seconds | Unit |
| `testForeignSourcesAndNonChannelBrowseIDsAreUnavailable` | Saavn/Gaana, invalid video/channel IDs, name-only/wrapper artist IDs | Unit |
| `testOnlyMatchingOwnedPlaylistMenuAndHeaderAreAccepted` | Ownership and system/foreign exclusions | Unit |
| `testAcknowledgementMustMatchTargetAndExpectedState` | Playlist receipt, channel boolean, wrong targets, anonymous like-state read | Unit |
| `testMalformedUnknownAndGatedHTTP200NeverConfirmsOrRetries` | Malformed/empty/unknown/gated responses, one request | Fake URLSession integration |
| `testAmbiguousNetworkAndServerFailureHaveOneAttempt` | Timeout, offline, connection loss and 503, no replay | Fake URLSession integration |
| `testAuthorizationRejectionAndRateLimit` | 401/403/429, cooldown, signed-out/error envelope | Fake URLSession integration + unit |
| `testPlaylistOwnershipIsRecheckedBeforeAnyMutation` | Wrong owner yields only read preflight | Fake URLSession integration |
| `testPlaylistAddAndLikeUseIndependentAcknowledgement` | Add receipt, like/unlike fresh exact-state confirmation | Fake URLSession integration |
| `testOwnedPlaylistPaginationAndRepeatedCursorBound` | Two-page list, repeated token stops | Fake URLSession integration |
| `testDeclaredAndChunkedOversizeResponsesAreRejected` | Header/body response bounds | Fake URLSession integration |
| `testRedirectDelegateRefusesEvenSameHost` | Same-host and foreign redirect refusal; suspended tasks only | Unit delegate contract |
| `testRetiredAccessNeverStartsARequest` | Revoked admission makes zero requests | Fake URLSession integration |
| `testSignedOutOptOutAndOfflineNeverReachTransport` | Controller authorization/offline gates | Unit |
| `testLegacySessionDecodesButRequiresReconnectForWrites` | Legacy session remains usable and byte-preserved, write enable refused | Memory Keychain integration |
| `testPermissionSurvivesSameSessionButNotAccountOrDeviceReplacement` | Default off, same-session restore, device-local permission absence, replacement binding | Memory Keychain integration |
| `testStrictPermissionRecordsAndConcurrentEditsArePreserved` | Corrupt/future/wrong-type/external edit preservation | Memory Keychain integration |
| `testFailedRevokeDisablesInMemoryAndShowsRetryError` | Failed durability blocks current process and surfaces retry | Unit |
| `testDuplicateTapsAreDroppedAndSessionSwitchRetiresStaleCompletion` | Single admission, sign-out/new session, stale context/completion | Unit |
| `testRevokeCancelsRealFakeSessionTransferAndNeverConfirms` | Disable cancels delayed URLSession task and reports uncertainty | Fake URLSession integration |
| `testPlaylistSelectionRequiresFreshListFromThisContext` | Unloaded/foreign/stale selection rejected | Unit |

OSLog output is not captured/asserted by these tests. Native Keychain accessibility/device migration, actual redirect delivery, real-account responses, page-cap/deadline timing and the five-minute selection timeout remain unverified. Phone/SE/iPad workflows passed; fixtures do not establish VoiceOver or physical-device acceptance. No live-write test was performed. Provider acceptance requires a listener-confirmed action on the intended account.
