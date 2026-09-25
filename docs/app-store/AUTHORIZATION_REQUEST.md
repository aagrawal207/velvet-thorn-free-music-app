# Breezy authorization request

**Draft, not sent.** The owner chose to pursue authorization after build 1.0.0 (4) was uploaded and attached to the App Store draft. This document requests a permitted product/integration path; it does not claim existing permission or predict approval.

The owner authorized automating eligible permission applications and confirmed they will apply as an individual. A dedicated Breezy Google Cloud project has been created in the personal account, and YouTube Data API v3 shows Enabled. Project details were verified in the console on 2026-09-24. The owner clarified that `aagrawal207@gmail.com` is their own Google account, not an external Google/YouTube contact. They authorized posting the generic intake-routing question to the official public issue tracker without Breezy details, project IDs or credentials. A formal application still needs legal/contact details, usage estimates and required evidence; legal acknowledgements require owner review. The app-specific permission inquiry remains unsent.

## Standard API quota

The enabled project already has the included YouTube Data API quota. A quota-extension application is not needed to use documented API operations within those limits and the applicable policies. The permission inquiry below concerns Breezy's native audio-only, background and offline experience.

The [Breezy quota page](https://console.cloud.google.com/apis/api/youtube.googleapis.com/quotas?project=breezy-509601) was checked on 2026-09-24:

| Daily allocation | Verified limit |
| --- | --- |
| General quota, shown as Queries per day | 10,000 units |
| Search Queries per day (`search.list`) | 100 calls in its separate quota bucket |
| Video Uploads per day (`videos.insert`) | 100 calls in its separate quota bucket |

These are project-wide allocations shared by the app's users, not per-listener allowances. [Google's current quota documentation](https://developers.google.com/youtube/v3/determine_quota_cost) states that daily quotas reset at midnight Pacific Time, typical video/channel/playlist list reads cost one unit, and each additional search-results page consumes another search call.

The standard Data API supports video search, metadata, channels and playlists. It does not provide the direct audio streams used by Breezy's native player or grant an exception for extracting audio, background playback or offline caching. Normal YouTube playback follows the embedded-player requirements. Using the included quota does not resolve those playback requirements or turn the prototype into an approved integration.

## Official starting point

YouTube's [compliance guide](https://developers.google.com/youtube/terms/developer-policies-guide) directs developers who are unsure whether their service is allowed to request an [API Compliance Audit](https://support.google.com/youtube/contact/yt_api_form). The [Developer Policies](https://developers.google.com/youtube/terms/developer-policies) also link that form for certain written-approval requests.

The current form is titled **YouTube Data API Services: Audit and Quota Extension Form**. On 2026-09-24, Section 1 offered only these request types:

- "Complete a compliance audit to request for additional quota"
- "Complete a compliance audit to keep current quota (requested to complete re-audit)"

Neither describes an initial product-permission inquiry without a quota increase or a requested re-audit. Section 5 offers "No change / Default quota (10k quota points)", but that does not resolve the request-type mismatch. Ask YouTube which intake or selection applies. Do not claim a requested re-audit or invent quota requirements to fit the form.

The form is not a published self-service license for an audio-only YouTube Music client. Describe the permission question explicitly and request routing to the appropriate YouTube product, partnerships or licensing team. An existing Google or YouTube partner contact is another route if the owner has one. YouTube's developer site also links its [official issue tracker](https://issuetracker.google.com/issues/new?component=186600&template=874803) for bugs and feature requests. The [posted routing question](https://issuetracker.google.com/issues/565837697) concerns the form mismatch; product permission remains a separate request.

Standard API credentials, OAuth verification, a quota increase or an ordinary audit result do not themselves waive restrictions on audio separation, background playback or offline caching. Those features are restricted by the published policies; YouTube may decline the requested scope or require a different implementation.

## Information for the request

| Item | Prepared information / owner input |
| --- | --- |
| App | Breezy - Stream Music & Chill; bundle `com.agraabhi.ganabajana` |
| Status | iPhone/iPad prototype, minimum iOS 18, with widgets and paired Watch controls; build 1.0.0 (5) is uploaded and attached to an App Store draft, not publicly released |
| Applicant | Individual, confirmed by the owner. Full legal name **Abhishek Agrawal**, confirmed September 25 UTC. Use `self` for the organization's legal name as instructed by Google's form |
| Developer contact | **Abhishek Agrawal**, `aagrawal207@gmail.com`; owner-confirmed legal applicant and primary contact |
| Google account / external contact | Owner confirmed `aagrawal207@gmail.com` is their own applicant account. No private recipient has been provided; the generic routing question is posted as issue `565837697` |
| Legal address | Owner enters it directly in Google's form; do not store it in this repository |
| Website / app access | Public Support page is available; an accessible feature demo/review channel still needs to be arranged. The App Store Connect draft is not a public download URL |
| Privacy policy | [Published policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) |
| Terms of service | Apple supplies the default EULA and the API returned no custom EULA record. Google's form separately requires accepted terms documentation; that evidence is pending |
| Google Cloud project | [Breezy](https://console.cloud.google.com/home/dashboard?project=breezy-509601), project ID `breezy-509601`, project number `321550855021`; personal account `aagrawal207@gmail.com`, No organization |
| API setup | [YouTube Data API v3](https://console.cloud.google.com/apis/api/youtube.googleapis.com/metrics?project=breezy-509601) is enabled. The phone uses an app/API-restricted key for exact-recording language/duration metadata, with live restriction checks passed. This does not authorize the prototype's playback or caching |
| Audience and volume | General music listeners. Owner expects **fewer than 1,000 Data API requests per day** at initial launch, across all installations. This is a forecast, not measured usage or a quota-increase request |
| Revenue | Free download with optional repeatable one-time tips. Tips unlock no music or functionality |
| Territories | Current App Store draft enables 175 territories; actual distribution must be limited to whatever an agreement permits |
| Evidence | A truthful full-feature demonstration, architecture/data-flow description, player/cache behavior, provider interfaces, metadata retention and account/deletion flows |

The form includes required legal acknowledgements, including conditions for supplied demo credentials. The owner must review and accept any such terms personally. Do not submit passwords, signing keys or real-user account cookies as demonstration material.

`artifacts/Authorization-20260925/google-application-draft.json` contains the prepared form answers with the confirmed legal name and initial usage forecast. Request type, owner-entered address and usable review access remain unset. The form was rechecked on September 25 UTC: its request-type mismatch remains, and it requires privacy/homepage/terms evidence in image or PDF form. Terms URL is optional, but terms documentation is required. Apple returned no custom EULA record; its [standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) applies by default under [Apple's documented rule](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/). This does not establish that the current evidence or integration meets Google's review requirements.

The form's endpoint list includes `youtube.videos.getDownloadUrl`, but the [public Videos reference](https://developers.google.com/youtube/v3/docs/videos) does not document that method and its presumed reference route returned 404. No access or playback permission is inferred from a quota-form option. The prepared endpoint selection is only `youtube.videos.list`, which is what the current official metadata client uses.

Project and API readback: `artifacts/YouTube-authorization/google-project-20260924.json`. Subsequent owner-approved build-5 work adds a restricted client credential and official recording-language/duration metadata. The credential's value stays out of this document and Git. `api-key-20260924.json` and `metadata-probe-20260924-01.json` in the same artifact directory record restrictions and live checks. Playback permission remains a separate request.

## Posted intake-routing question

**[Issue 565837697](https://issuetracker.google.com/issues/565837697) is posted and verified.** After the owner completed Google's CAPTCHA, one Create action was submitted at 2026-09-25 01:39 UTC. Firefox readback confirmed the exact title, complete description, reporter account and New status in Public Trackers > YouTube API Service. No reply was present at verification.

**Answered on 2026-09-25.** The YouTube API team replied that adding an initial-review request type is infeasible and closed the issue as Won't Fix (Infeasible), with instructions for the existing form: Section 1 "Complete a compliance audit to keep current quota (requested to complete re-audit)", Section 5 "No change / Default quota (10k quota points)", and this note in an open-text field: "Submitting for a proactive initial compliance review per the Developer Policies Guide; no additional quota is requested and a re-audit was not requested by YouTube." The API Audit team reads such notes. `artifacts/YouTube-authorization/intake-routing-20260924/reply.md` preserves the forwarded text and `reply.json` the resulting form answers, which are now applied in `artifacts/Authorization-20260925/google-application-draft.json`. This settles the intake route only; it grants no product or content permission.

The post excludes Breezy details, project IDs, credentials and attachments. `artifacts/YouTube-authorization/intake-routing-20260924/draft.md` preserves the submitted text, and `posted.json` in that directory records the action/readback evidence. It asks which initial-review intake applies; no product/content authorization was granted. The private app-specific request below still needs a confirmed recipient and applicant information.

Title: Initial API compliance audit without additional quota: which request type applies?

The developer policy guide directs developers who are unsure whether their service is allowed to apply for an API Compliance Audit:
https://developers.google.com/youtube/terms/developer-policies-guide

The linked form currently offers only "Complete a compliance audit to request for additional quota" and "Complete a compliance audit to keep current quota (requested to complete re-audit)":
https://support.google.com/youtube/contact/yt_api_form

Which request type or intake should a developer use for an initial compliance/policy review when no additional quota is requested and YouTube has not requested a re-audit? Section 5 includes a default/no-change quota option, but neither Section 1 option describes this case. Please clarify the documented route or add an applicable request type.

## Draft request

Subject: Breezy product-permission and licensing inquiry for native audio playback

Hello YouTube API Services team,

I am developing Breezy, an iPhone and iPad music app, and would like guidance on whether YouTube offers an authorized integration or agreement for the product described below. Please route this inquiry to the appropriate YouTube product, partnerships or licensing team if it is outside the API compliance team's scope.

The app is not publicly released. Its current prototype uses undocumented YouTube Music catalog requests and extracts media URLs for a custom native audio player. The official YouTube Data API supplies recording audio-language and duration metadata. I am seeking explicit guidance and written authorization for the product, including any required integration changes. I do not represent this prototype as an approved YouTube playback client.

The proposed experience includes:

- Native audio-only playback, including background and Lock Screen playback, rather than a visible embedded YouTube video player.
- Complete-song caching for offline use, with storage limits and user deletion controls, plus local packet-copy container preparation for compatible playback.
- Audio transitions such as crossfade and Automix.
- Song, artist, album and playlist search, related-song radio, metadata/artwork display and personal recommendations based on the user's listening.
- Device-local library controls, optional iCloud library-data sync, Home Screen widgets and paired Apple Watch playback controls.
- Optional account access through whatever authentication method and scopes YouTube authorizes. The prototype currently retains a user-selected YouTube session in the device Keychain; that approach would need to be reviewed or replaced.

Breezy is intended to be free to download, with optional one-time tips supporting development. Tips grant no features or music access. The prototype does not use YouTube's embedded player or its advertising presentation.

Could you confirm:

1. Whether YouTube is willing to authorize this native audio-only, background and offline experience, and which features would need to change?
2. Which documented APIs, SDKs, authentication, branding, advertising and playback-reporting requirements would apply?
3. Whether an agreement could cover the necessary music recording/composition rights, offline copies, metadata and artwork, and what additional rights-holder or lyrics licenses would be required?
4. What territory, user-subscription, cache-retention and commercial restrictions would apply?
5. What written authorization could be provided for Apple's App Review requirements under Guidelines 5.2.2 and 5.2.3?
6. Which user/request data would the authorized integration retain, for which purposes, and how would it be linked or combined with data from other sites or apps? Please include advertising uses and required consent/deletion controls so the app's privacy disclosures can match the integration.

I can provide a feature demonstration and a technical/data-handling description through your approved review channel. The public privacy policy is available at:
https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md

App name: Breezy - Stream Music & Chill
Bundle identifier: com.agraabhi.ganabajana
Developer contact: aagrawal207@gmail.com
Google Cloud project ID: breezy-509601
Google Cloud project number: 321550855021

Thank you,
Abhishek

## Before relying on a response

Obtain written terms that identify the developer/app and explicitly cover the permitted functionality, content, territories and distribution. Ask whether music rights are included or need separate arrangements with labels, publishers or other licensors. A music/IP licensing lawyer should review that coverage and any proposed exceptions. A generic API approval or the absence of a rejection is not the requested authorization.

Apple's [5.2.2–5.2.3 requirements](https://developer.apple.com/app-store/review/guidelines/#intellectual-property) and YouTube's [Terms of Service](https://www.youtube.com/t/terms) remain the release-record references. FFmpeg recipient source/relink delivery and App Store privacy/age-rating declarations are separate requirements.

## Other provider inquiries

Private inquiries were sent from the developer account to MetaBrainz's published support address and the contact in LRCLIB's repository README. They ask about the optional-tip model, API/data reuse and deployed request-data retention. Gmail showed Message sent for each, and a scoped Sent search returned exactly the two expected subjects. No attachment, credential, paid-plan enrollment or legal acceptance was sent. `artifacts/Authorization-20260925/provider-inquiries.json` records recipients, exact text and verification.

MusicBrainz's [data license](https://musicbrainz.org/doc/About/Data_License) distinguishes CC0 core data from supplementary data. Its [hosted API documentation](https://musicbrainz.org/doc/MusicBrainz_API#General_FAQ) separately directs commercial users to plans or contact. MetaBrainz answered on 2026-09-25 (`artifacts/Authorization-20260925/metabrainz-reply.md`): the app barely qualifies as commercial, no fee is asked now; register as a [Stealth Start-Up supporter](https://metabrainz.org/supporters/account-type) ($0/month, needs a MetaBrainz account with a verified email), keep to the [API rate limits](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting), attribute MusicBrainz in the app's help/about area (and optionally the store entry), and get back in touch at about $500/year of income. Non-CC0 data such as genres is permitted under that setup. The app already rate-limits to one request per second with a contactable User-Agent; the acknowledgements now name MusicBrainz and the MetaBrainz Foundation. The supporter registration is an owner account action and is not done. LRCLIB's server-software license does not settle rights to returned lyric text; its response remains pending.
