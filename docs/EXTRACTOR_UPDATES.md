# Extractor Updates

## Scope and Status

R18 adds a device-local compatibility package engine, a Files import screen and data-only YouTubeKit hooks. The engine can accept a new package after installation without rebuilding the app. An installed app must first contain this engine: earlier delivered builds cannot gain the mechanism through a JSON file alone.

The concrete YouTube and composite resolvers implement generation-fenced resolution and invalidation. Production center ownership, startup, Settings navigation, invalidation and playback confirmation are integrated. No feed or publisher key is configured. The screen offers manual Files import and says automatic upstream updates are unavailable. No hosting or publication was performed.

Verification is in progress. The coordinator reports passing Core-02, Regression-01, vendor compatibility and phone UI-02 scopes. [VERIFICATION.md](VERIFICATION.md) owns counts and run boundaries. No latency improvement is claimed.

## Extraction Path and Supported Repairs

`YouTubeAudioFastPath.extract` reads cookie-free watch HTML for visitor data, then sends the existing VISIONOS player request. Formats carrying signature or `n` challenges fall through to full extraction. `YouTube.js` downloads player JavaScript using the existing receipt-limited transport, with a 12,000,000-byte cap. It retains the original source. `Extraction.applySignature` invokes `SignatureSolver`, which ordinarily runs the bundled yt-ejs helper with that player source. `Cipher` is a legacy implementation; updating only its regexes would miss the current playback path.

The rule schema exposes three surfaces:

| Surface | Data supplied by package | Actual consumer |
| --- | --- | --- |
| Signature timestamp | Up to eight literal field names | `Extraction.extractSignatureTimestamp`, before bundled matching |
| Visitor data | Up to eight literal field names | `YouTubeAudioFastPath.visitorData`, before `VISITOR_DATA` / `visitorData` |
| Signature / throttling transform | Exact SHA-256 of original UTF-8 player source and bounded operation lists | `SignatureSolver.batchSolve`, called by `Extraction.applySignature` |

A player entry may supply `signature`, `throttling`, or both. Supported operations are `reverse`, `dropFirst`, `swapFirst` and `rotateLeft`. The latter two reduce their argument modulo the current nonempty length. `reverse` requires argument zero. Empty results, non-ASCII challenges and invalid bounds fail rather than guessing. A missing player hash or missing challenge plan leaves that work with the bundled solver. Rules are applied to the original challenges, not to code text. Package content is never passed to JavaScriptCore.

This can repair field renames, and transform sequences expressible with those operations when the bundled solver cannot recognize a particular player. Exact player hashes prevent an old plan from silently applying to changed source. Most complex future `n` algorithms will not fit this small instruction set. New algorithms, parser/helper changes, client identities, endpoints, anti-bot or account behavior, media formats and native playback changes still require an app update. Existing bundled JavaScript behavior has no new execution-time guarantee; the new native-rule path has finite work bounds.

## Package Format

The file is UTF-8 JSON with this envelope. `payload` and `signature` use standard base64. Only these envelope keys are accepted:

```json
{
  "formatVersion": 1,
  "payload": "<base64 of exact payload bytes>",
  "sha256": "<64 lowercase hexadecimal characters>",
  "keyID": "<configured publisher key identifier>",
  "signature": "<base64 Ed25519 signature>"
}
```

`keyID` and `signature` are both omitted for unsigned manual imports. A partial signature pair, unknown key or bad signature is rejected even for manual imports. Manual trust does not bypass a failed claimed signature.

The decoded payload has exactly these keys:

```json
{
  "schemaVersion": 1,
  "extractorABI": 1,
  "appBundleID": "com.agraabhi.ganabajana",
  "minimumAppBuild": 7,
  "maximumAppBuild": 8,
  "revision": 1,
  "rules": {
    "timestampKeys": ["signatureEpoch"],
    "visitorKeys": ["VISITOR_TOKEN"],
    "players": []
  }
}
```

App compatibility uses integer `CFBundleVersion`, the exact bundle identifier and extractor ABI 1. Both build endpoints are inclusive. Revisions are positive integers through 9,007,199,254,740,991 and must exceed the highest activated revision on this installation. A rollback does not lower that floor. Unknown fields, schema versions and operations fail closed. Optional player plans must be omitted rather than `null`.

A player entry has this shape, using a real source digest in place of the placeholder:

```json
{
  "sha256": "<SHA-256 of exact original player UTF-8 bytes>",
  "signature": [
    {"operation": "reverse", "argument": 0},
    {"operation": "dropFirst", "argument": 2}
  ]
}
```

### Bounds

| Input | Limit |
| --- | --- |
| Encoded package | 65,536 bytes, enforced while receiving and reading Files |
| Decoded payload | 32,768 bytes |
| JSON nesting | 16 levels before JSON object parsing |
| Field names | Eight per surface; 1–64 ASCII letters, digits, `_` or `$`; no duplicates |
| Player entries | 16 unique SHA-256 hashes |
| Each transform | 1–64 operations; arguments 0–4096 |
| Native-rule challenges | 1–4096 printable ASCII bytes each; at most 256 per type; 65,536 combined bytes per matching-player batch |
| Watch HTML inspected for aliases | 4,000,000 bytes |
| Player source inspected / hashed | 12,000,000 bytes |
| Visitor value | 1–4096 bytes from a compiled ASCII alphabet |
| Timestamp value | Five or six decimal digits |
| Disk state | 393,216 bytes including retained package envelopes |

There are no arbitrary regular expressions. Field names are checked as literal identifiers, escaped and interpolated into compiled patterns with finite constant quantifiers. Packages cannot change capture expressions, flags or limits. They cannot change URLs, headers, cookies, client parameters, JavaScript helpers or native libraries.

### Example

[`examples/extractor-compatibility-v1.json`](examples/extractor-compatibility-v1.json) is a complete unsigned manual-import package for builds 7–8. Its payload checksum is `54648f2816e6d67b108386417d6a67d1855aba3b1ab13b18767bd1b90ef4daf5`. It recognizes the field names in the adjacent synthetic [watch](examples/extractor-fixture-watch.txt) and [player](examples/extractor-fixture-player.txt) fixtures. It supplies no player transform and is not a claim to repair a current live YouTube incident. The fixtures contain no account data or signed media links. After activating revision 1, another import needs a higher revision.

The example's build range is a validator input, not evidence that R17 build 7 contained the update engine. The integrated engine belongs to local R18 build 8; delivered build 6 cannot import this package.

To author a manual package, encode the payload once, hash those exact bytes with SHA-256, base64 those same bytes and encode the envelope. Changing whitespace inside the payload requires a new checksum and signature; changing envelope whitespace does not. Player hashes also include whitespace and trailing newlines. Do not install a locally modified player script under the digest of the original.

## Trust and Optional Feed

An unsigned manual import requires Files selection, validation and a separate **Trust Source and Activate** confirmation. The screen distinguishes compatible data and a valid checksum from authenticated publisher identity. The confirmation retains an opaque candidate ID, so a later candidate cannot consume approval intended for an earlier file.

An optional `ExtractorUpdateFeed(url:trustedKeys:)` must be supplied by the host. No endpoint is inferred from YouTubeKit's unrelated remote-extraction fallback. Feed URLs require HTTPS, an ordinary TLS trust evaluation and no embedded credentials, query, fragment or nonstandard port. Redirects, including same-origin redirects, are refused. Configuration accepts one to four pinned 32-byte Ed25519 public keys. Feed responses must be signed by a key in that feed's configured set, not merely another key trusted for manual import.

Ed25519 signs this exact byte sequence:

```text
UTF8("Breezy.ExtractorUpdate.v1\n") || raw_payload_bytes
```

The signature authenticates the payload's app range, revision and rules. `sha256` independently detects damaged payload bytes. `keyID` selects a pinned key; a package cannot add or rotate keys. A publisher must provision public keys through a trusted app configuration, retain signing keys outside the app/repository and use monotonically increasing revisions. Keep verification keys for retained packages during rotation; removing one makes those stored signatures unverifiable and forces the fail-closed storage path. No private key is supplied or persisted. Tests generate ephemeral signing keys in memory.

Configured checks run only on a user tap, once per in-flight center operation. The production transport creates a cookie-free ephemeral session with no credential storage or URL cache, an eight-second request timeout and twelve-second resource timeout. GET has no body, media URL, recording ID, account cookie, referrer or library data. The endpoint and ordinary connection metadata, including IP address, are necessarily visible to the configured publisher. HTTP authentication challenges other than TLS server trust are cancelled. Error bodies and URLs are not copied into app diagnostics or UI errors. No periodic, launch-time or background fetch is scheduled.

There is no expiration clock in schema 1: the durable revision floor blocks replay below an activated revision, but it cannot detect a publisher withholding a newer revision. This is a tap-to-check compatibility facility, not a guaranteed latest-version service. Removing app data or maliciously replacing an entire historical device-local state is outside its rollback protection; there is no server-side installation identity or Keychain counter.

## Activation and Recovery

`Application Support/GanaBajana/ExtractorUpdates/state.json` contains a checksummed state document with the revision floor, active candidate, last confirmed package and previous confirmed package. The containing directory is excluded from backup and is separate from library/iCloud data. No raw player source, media URL, challenge or imported Files path is stored.

Activation revalidates the candidate against the current revision floor, verifies the disk baseline and atomically replaces the single state file. Only then does it publish a validated immutable rule snapshot through YouTubeKit's lock-protected registry. Failure to write leaves the previous runtime and revision intact. All host mutations run on the main actor without an intervening await between persistence and publication. Use one production center across windows.

New candidates are provisional. A successful HTTP response or a computed signature is not proof of playback. `confirmPlaybackSucceeded(generation:)` promotes a candidate to known-good only when the caller's extraction generation matches both the center and current registry. The model receives actual player progress through `onFreshExtractionPlayed`. Complete cached media cannot certify new rules.

Confirmation records successful playback under that generation, not verification of every player entry in the package. Publisher-side testing still has to cover each supplied transform.

Unconfirmed candidates revert to the last confirmed package on relaunch, or bundled rules if no package was confirmed. The revision floor survives that recovery. Explicit rollback from a provisional package selects the last confirmed package; rollback from a confirmed package selects its predecessor. **Use Bundled Rules** persists the bundled choice without lowering the revision floor. Existing playing media need not be interrupted.

Corrupt, oversized or unsupported state is preserved, uses bundled rules and blocks further writes. There is no destructive reset button that silently discards the revision floor. An external disk edit also prevents an overwrite. A compatible state whose packages no longer match an app build can retire those packages while preserving the floor. Interrupted atomic replacement leaves the old or new complete state; provisional-startup recovery handles an activation interrupted before confirmation.

Preparation has a separate operation generation. A new import, cancellation, rollback or bundled selection retires the old receive task. A transport that ignores cancellation still cannot publish a late candidate. `SignatureSolver` captures a rule snapshot at construction and checks its generation before and after solving. The fast path captures before the watch request and checks before returning results. Resolver-level fences cover work spanning those calls.

### Resolver Generation and Playback Evidence

`ResolvedStream.extractionGeneration: UInt64?` is in-memory evidence, defaulting to nil in the existing initializer. It is independent of `playbackSource`, which continues to describe the provider of the bytes. The YouTube resolver captures `YouTubeKitHooks.extractionCompatibility.generation` before resolution work, includes it in its coalescing key and URL-cache entries, and verifies the global registry after extraction/probes and before admitting or returning results. Fast, full and optional remote-fallback results carry the captured stamp. A same-generation prefetched or cached remote URL retains its original stamp. No return-time restamping can make an old URL fresh.

Each operation checks the registry directly; it does not wait for an asynchronous app invalidation callback to reach the resolver actor. A new-generation request synchronously retires the old actor state before checking its URL cache or joining a flight. A late result cannot populate a replacement flight's cache. Hedged branches, speculative warmups, quality reloads and background-plan selection keep their existing selection policy and add the same pre/post-generation checks. A stale operation throws `CancellationError` rather than retrying a remote fallback under mismatched rules.

`YouTubeStreamResolver.invalidateExtractionCompatibility()` clears stale signed-URL entries, Opus-failure cooldowns and prefetch downloads, and cancels coalesced extraction flights. It is idempotent for the current registry generation, so a delayed or duplicated callback does not discard newly resolved URLs. It does not delete, demote, unpin or replace complete audio files. Existing file-backed playback remains valid. The serialized `YouTubeExtractionWorker` captures before queueing and checks again after its predecessor drains; invalidation cancels pending jobs but keeps the old tail as a barrier because an executing JavaScript call may still be unwinding. At most 32 worker calls may be pending.

`CompositeStreamResolver` preserves both the source and generation of YouTube results, including Gaana-to-YouTube fallback streams. Gaana can retain a YouTube URL in its own cache. The composite refuses an obsolete stamp and makes at most one forced source refresh to replace it. If that refresh still joins a retiring old flight, it cancels rather than returning old audio. Its bounded actor tracks up to 32 Gaana resolution calls and cancels old pending work on invalidation. Native Saavn/Gaana results do not acquire a YouTube stamp. Gaana's private cache is not destructively cleared; obsolete entries are unusable through the composite and are replaced on resolution.

Every complete cache/download result has a nil stamp through `CachedAudio.stream`. This includes offline reads, cached quality fallbacks, foreground Opus preparations and downloads completed during this session. An Opus store can reuse a previously prepared immutable file, so even that path conservatively supplies no update-confirmation evidence. A background plan carries its fresh stamp only in its in-memory `stream`; sidecar metadata and durable queue records do not encode it, and published files cannot confirm a package. Playback success must use a non-nil stamp from the exact newly playing `ResolvedStream`, never a current registry lookup or a track-level trace.

## Integrated APIs and Wiring

| API | Responsibility |
| --- | --- |
| `ExtractorUpdateCenter(directory:app:feed:manualTrustedKeys:write:metric:)` | One model-owned production center at `ExtractorUpdateStore.defaultDirectory`; temporary/injected directory for fixture hosts |
| `start()` | Publishes restored rules once, before production resolver construction; performs no update-network request |
| `ExtractorUpdatesView(controller:)` | Settings destination; reads the existing `MusicAppModel` environment only for shared Settings chrome |
| `prepareImport(from:)` | Read a security-scoped Files URL off-main and stage a validated candidate |
| `checkFeed()` | Stage a signed candidate from the explicitly configured feed; reports unavailable when no feed exists |
| `pendingID`, `pendingRevision`, `pendingPublisherVerified` | Present the candidate and retain its ID through confirmation |
| `activatePending(id:trustingManualSource:)` | Activate only that reviewed candidate, after explicit manual-source trust when unsigned |
| `runtimeGeneration` | Current center publication generation; do not substitute it for a playing stream's captured stamp |
| `onRulesChanged` | Invalidate pending extraction work and signed-URL caches after durable activation/rollback; receives the new generation |
| `YouTubeStreamResolver.invalidateExtractionCompatibility() async` | Retire stale URL cache/flights and invalidate the shared serialized extraction worker |
| `CompositeStreamResolver.invalidateExtractionCompatibility() async` | Retire old Gaana wrapper flights and forward invalidation to YouTube |
| `ResolvedStream.extractionGeneration` | Optional captured evidence passed with the resolved stream and any standby stream; nil for complete files and non-YouTube sources |
| `confirmPlaybackSucceeded(generation:)` | Confirm genuinely successful newly extracted playback from the captured generation |
| `rollback()`, `useBundled()`, `cancel()` | Recovery and preparation cancellation |
| `YouTubeKitHooks.extractionCompatibility` | Thread-safe immutable vendor snapshot |
| `YouTubeKitHooks.installExtractionCompatibility(_:)` | Validated synchronous vendor publication; the center owns production use |

`MusicAppModel` starts the production center before constructing production providers/resolvers. `onRulesChanged` cancels warmups and replaces the model's invalidation task, calling the composite or concrete YouTube invalidator. Those methods read the latest registry, so delayed delivery cannot admit stale media or discard fresh work. The callback does not restart or seek current playback.

`PlayerController.onFreshExtractionPlayed(UInt64)` emits the captured stamp once when a playing, non-seeking song advances. Active installation and standby activation retain `ResolvedStream.extractionGeneration` only for non-file streams; selection and pipeline invalidation clear it. The model forwards the stamp to `confirmPlaybackSucceeded(generation:)`, where current center/registry equality is checked before durability. Readiness, probe success, prefetch and background publication do not confirm rules. A current-registry lookup never substitutes for the stream's stamp.

Settings > Account & Connection > **Extractor Updates** (`settings.extractorUpdates`) passes the same center to `ExtractorUpdatesView`. Production has no feed or trusted publisher keys; no launch, periodic or background update check occurs.

## Metrics

| Event | Closed values | Purpose |
| --- | --- | --- |
| `event=extractor_update` | `outcome=prepared/activated/confirmed/rolledBack/bundled/rejected/cancelled/recovered`; `reason=none` or an `ExtractorUpdateFailure` enum value | Distinguish validation, durability, recovery and cancellation outcomes |
| `event=extraction_compatibility` | `outcome=bundled/updated/partial` | Identify whether a solver batch used a matching native compatibility plan |
| `event=signature_solver` | `reuse=0/1`, `preprocessed=0/1`, `outcome=success/failure`; `prepare_ms`, `solve_ms` | Prepared JavaScriptCore context reuse (two per process, keyed by player script) |
| `event=signature_solver_evicted` | `reason=capacity/failure/memory_pressure/released` | Why a prepared context left the cache |
| `event=extractor_resolution` | `outcome=invalidated/stale/queue_full` | Record actor retirement, direct global-fence rejection and bounded admission refusal |

Host events use the existing `Logger` convention; vendor events use `os_log`. No URL, player hash, revision/generation, challenge, cookie, path, publisher key ID or provider response is a metric dimension. Existing resolution/cache success events remain the success path. Store-write failure tests assert the host outcome sequence. Vendor and resolver-fence metric output is source-reviewed, not captured by tests. Fence events count individual checks/retirements, not unique playback attempts.

## Test Coverage

| Case | Test source | Level |
| --- | --- | --- |
| Good Ed25519 signature, bad signature with good hash, recomputed hash after payload tamper, unknown/wrong key, unsigned feed | `ExtractorUpdateTests.swift` | Unit |
| Manual checksum without publisher claim, incompatible schema/ABI/build, stale/invalid revision, arbitrary config/regex/code fields, size/nesting limits | `ExtractorUpdateTests.swift` | Unit |
| Old visitor fixture renamed, fails bundled, passes activated rules, fails again after rollback | `ExtractorUpdateTestsPersistence.swift` | Host integration with real fast-path parser and disk state |
| Confirmed relaunch, provisional recovery, rollback floor, stale playback generation, failed write, external edit, corrupt/future/oversized state, app upgrade | `ExtractorUpdateTestsPersistence.swift` | Persistence integration |
| Late cancelled receive, parent task cancellation, newer import superseding an older receive, bundled recovery during receive, stale trust confirmation, unconfigured feed | `ExtractorUpdateTestsPersistence.swift` | Async unit/integration |
| Bodyless cookie-free feed request, unknown-length overflow, status errors, denied redirects, Files bounds/symlinks | `ExtractorUpdateTestsTransport.swift` | Transport/file integration with isolated fixtures |
| Existing timestamp fixture renamed and recovered through installed vendor rules, alias and transform bounds | Vendor `ExtractorCompatibilityTests.swift` | Unit |
| Actual `Extraction.applySignature` manifest path, exact-player hash miss, rollback, stale solver, partial bundled fallback | Vendor `ExtractorCompatibilityTests.swift` | Vendor integration with synthetic raw player/challenges |
| Fresh fast/full/remote stamp; late fast/full result before actor callback; coalesced old waiters; prefetched URL invalidation; late idempotent callback; delayed validation and hedge retirement | `ExtractorUpdateResolutionTests.swift` | Resolver integration with controllable extraction/probe gates |
| Disk/download nil stamps; bytes retained through invalidation; stale background plans; sidecar omits generation; quality-reload cancellation; composite fallback source/stamp preservation and stale private-cache replacement | `ExtractorUpdateResolutionTests.swift` | Cache/composite integration with existing local fixtures |

Core-02, Regression-01, vendor compatibility and phone UI-02 have passing coordinator-reported coverage; [VERIFICATION.md](VERIFICATION.md) owns the exact scopes. `R18IntegrationTests` checks that cached AAC cannot confirm a provisional package and that relaunch recovers bundled rules. The 32-call admission limit and real JavaScript tail drain remain source-reviewed rather than live-solver evidence. Current upstream repairs, genuine user-supplied Files packages, real feed HTTP/TLS behavior and hardware playback acceptance remain unverified. Synthetic aliases/transforms demonstrate the bounded mechanism, not automatic repair of arbitrary future YouTube changes.

No external research fetches were used. The implementation was based on the current vendored YouTubeKit source and repository fixtures. Upstream provenance remains in [the vendor patch record](../Vendor/YouTubeKit/GANABAJANA-PATCH.md).
