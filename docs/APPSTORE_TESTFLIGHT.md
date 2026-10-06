# Breezy TestFlight preparation

**30 September 2026: build 1.0.0 (11) delivered after explicit TestFlight upload authorization.** Apple processing is VALID and internal testing is ready. The existing internal Friends group has access and en-US What to Test notes are saved. The public App Store draft still has build 6 attached; public App Store and Beta App Review submission were not performed.

## Current evidence

The build-11 delivery used `asc 5.3.4 --profile personal --strict-auth`. [ASC_STATE.json](app-store/ASC_STATE.json) records the latest TestFlight delivery separately from the public draft's attached build. Earlier delivery artifacts remain frozen.

| Item | Observed state |
| --- | --- |
| App | `6815025307`, Breezy - Stream Music & Chill, `com.agraabhi.ganabajana` |
| iOS version | `1.0.0`, `2754a299-5b46-4e62-8f79-8bf80c6078d5`, `PREPARE_FOR_SUBMISSION` |
| App info / version localization | `49ab6f45-a195-4a95-9381-d9d61ae78108` / `508731a4-a244-4991-acaa-9dce56243aad` |
| Attached build | `6`, `e36b7e87-31d1-4ad6-b0bc-1ca428043353`, `VALID`, `APP_STORE_ELIGIBLE`, unexpired |
| Latest TestFlight build | `11`, `eed48919-97be-46a8-a3ca-b742f502d782`, `VALID`, `APP_STORE_ELIGIBLE`, unexpired |
| Uploaded iOS 1.0.0 builds | `3`, `4`, `5`, `6`, `11` |
| Build-11 beta states | Internal `READY_FOR_BETA_TESTING`; external `READY_FOR_BETA_SUBMISSION`; auto-notify enabled |
| Build-11 expiration | `2026-12-29T13:34:58-08:00` (29 December 21:34:58 UTC) |
| Beta review | Build 11 has not been submitted. Review contact fields were missing at the September 27 check and were not changed by this upload |
| TestFlight groups | Build 11 belongs to existing internal Friends group `9d8db968-fe22-494a-9ed6-3fb622eeecc4`, with explicit and all-build access. No group or invitation was created by this task |
| Beta text | Build-11 en-US What to Test saved and read back, localization `cf8e5ae6-bbad-4701-8a60-b07ec0bbc5c5`. App-level beta description was not changed |
| Historical beta validation | Build 6 had five errors and zero warnings on September 27. Build-11 notes now exist; external review-contact readiness was not revalidated |
| Public App Store review | Draft `43569019-e4a2-4875-9fa1-c79b72716763` is `READY_FOR_REVIEW` with zero items; not submitted |

The September 27 listing update changed three authorized fields in one version localization. Its canonical dry run and readback passed. This TestFlight upload did not change the public listing, screenshots, declarations or review state.

Prior values, selected non-sensitive readiness data and the mutation receipt are in `artifacts/TestFlight-Prep/20260927/`. The only missing-resource response was the explicit “no beta app review submission found” result; API authentication succeeded.

Build-11 archive, export, Apple validation, processing and remote IPA checksum receipts are in `artifacts/AppStore-1.0.0-11/`. The signed 20,713,556-byte IPA has SHA-256 `ed078358584f0e3561e72bd4041fb4bad2f5a780e1128ab41f24df8a61c67573`; remote MD5 matches. Frozen source hashes were rechecked after upload. The temporary signing keychain was removed without altering the original default or search list. Build-6 artifacts remain in their original directory.

## Copy and binary alignment

[Canonical listing](app-store/asc-metadata/version/1.0.0/en-US.json) describes build 6. Delivered **1.0.0 (11)** includes the uncommitted R17 to R21 features and notification-routing fix. [VERIFICATION.md](VERIFICATION.md) records its targeted automated and signed delivery checks. Frozen build-11 input hashes capture the delivered working tree. Store screenshots and review notes retain earlier provenance.

Build-11 What to Test is saved in `artifacts/AppStore-1.0.0-11/test-notes.txt` with a matching remote readback. The older [beta-description draft](app-store/testflight-next-build.md) remains local. TestFlight What to Test is build-specific and separate from the public App Store What's New field.

## Gates before sharing with a friend

1. **Device acceptance.** The owner reports constant physical testing and successful TV AirPlay audio. Build 11's TV lyrics, background transfers, lifetime sync, live radio, gain-up, account changes, song/artist Radio and system notification handoff retain the specific native acceptance limits in VERIFICATION.
2. **Beta setup.** Confirm the feedback address and beta review contact, including phone; supply accurate app-level beta description and any review access required by the binary. Build-11 What to Test is already saved. The beta review detail is separate from the existing public App Store review contact. External group setup remains pending; internal Friends access is recorded above.
3. **External testing and Beta App Review.** A friend should be an external tester. After authorization, configure an external group, submit the matching build for TestFlight App Review, and invite the friend after approval. An email invitation needs the friend's email address. Apple's [external-tester instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/) require full review for the first submitted build; later builds may not need full review. Internal testers are App Store Connect users with app access, not a reason to grant a friend team privileges.
4. **Distribution intent and content evidence.** Apple's [guideline 2.2](https://developer.apple.com/app-store/review/guidelines/#beta-testing) says TestFlight apps should be intended for public distribution and comply with App Review Guidelines. This needs an owner decision given the earlier local-only direction; preparing a friend beta does not authorize public submission. [Guidelines 5.2.2–5.2.3](https://developer.apple.com/app-store/review/guidelines/#intellectual-property) require permitted third-party service use and explicit authorization for media downloading. The existing provider/content authorization and recipient relinking questions remain unresolved in [release status](app-store/RELEASE_STATUS.md). Working streams, attribution and a processed binary do not establish permission or predict Apple's review result.

Apple permits testing each uploaded build for **up to 90 days**; expiry is tied to that build, not the date a friend accepts an invitation. See the [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/). Build 11's exact expiration is recorded above.

The authorized delivery archived, exported, validated and uploaded build 11 for TestFlight, then verified existing Friends access and saved test notes. No invitation, group creation, Beta App Review submission, permission change, legal form submission, privacy publication or Git write was performed. The public draft retains build 6. The historical public-store declaration errors are recorded in release status, not presented as fresh TestFlight API failures.
