# BabyLog — Release Checklist (v1.0, build 29)

Current source of truth for App Store submission. Supersedes the May
`appstore_submission.html` cheatsheet (which is stale on: AI model name, build
number, and the "Ethan hardcoded" warning — that personalization has since been
removed; the app is profile-driven).

App Store Connect app: https://appstoreconnect.apple.com/apps/6772348315

---

## Technical facts (verified in project)

| | |
|---|---|
| Bundle ID | `com.yewwee.BabyLog` |
| Version / Build | 1.0 / 29 |
| Min iOS | **26.0** (required for Apple Foundation Models) — installable only on iOS 26 devices |
| Devices | iPhone + iPad, portrait + landscape |
| Team | WPQCQE4HTE |
| Capabilities | increased-memory-limit only (no CloudKit / push) |
| Background | `fetch` + BGTask `com.babylog.feedRefresh` (declared in `Info.plist`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` (standard HTTPS only) ✅ |
| App icon | present (light/dark/tinted) ✅ |
| Privacy manifest | `BabyLog/PrivacyInfo.xcprivacy` ✅ (created — verify it's in the app target/bundle) |

---

## App information (one-time)

- **Name:** BabyLog
- **Subtitle:** AI-powered baby tracker
- **Primary category:** Health & Fitness  ·  **Secondary:** Lifestyle
- **Privacy Policy URL:** _host `PRIVACY.md` publicly and paste the URL_ (see Action items)
- **Support URL:** _needs a public URL_ — the repo `github.com/weewey/BabyLog` is **private**; make it public or use a GitHub Pages / Notion page
- **Marketing URL:** leave blank

## App Privacy questionnaire (ASC)

Answer **"Data Not Collected"** for every category. Accurate: all data is local
SwiftData, no analytics/ads/crash SDKs, no HealthKit, on-device AI. This matches
`PrivacyInfo.xcprivacy` (`NSPrivacyTracking = false`, no collected data types).

## Version 1.0 metadata

**Description** (the existing draft is good; optionally add the Apple Intelligence hook):
> BabyLog helps new parents track everything about their baby — feeds, diapers, growth, milestones, pumping, and medical appointments — all in one place.
>
> CHAT WITH YOUR DATA
> Ask the built-in AI assistant anything in plain English. "Log a 90 ml feed", "How much did baby eat today?", "Log a dirty diaper" — it understands and acts instantly. Powered by Apple Intelligence, running entirely on-device.
>
> TRACK WHAT MATTERS
> • Feeds — volume, time, and daily totals at a glance
> • Diapers — wet and dirty, with a daily count
> • Growth — weight, height, and head circumference charted over time
> • Pumping — session duration and volume
> • Milestones — first smile, first word, first steps
> • Medical — appointments synced to your Calendar with reminders
>
> PREP FOR THE DOCTOR
> One tap turns everything you've logged since the last visit into a shareable summary — feeds, growth, diapers, and milestones — narrated on-device.
>
> DESIGNED FOR ONE-HANDED USE
> Every button and label is accessible while your other arm is full. Large tap targets, clear contrast, and VoiceOver support throughout.
>
> PRIVATE BY DEFAULT
> Your data lives on your device only. Nothing is sent to any third-party server. The AI assistant runs entirely on-device — your conversations never leave your phone.

- **Keywords:** `baby,newborn,infant,feeding,diaper,tracker,pumping,growth,milestone,parenting,breastfeeding`
- **What's New:** First release. Track feeds, diapers, growth, pumping, milestones, and medical appointments — all from a single chat interface powered by on-device Apple Intelligence.
- **Promotional text:** Track your baby's day in seconds — just ask the AI.

## Age rating
All answers **None / No** → **4+**. (Note: it does not provide medical advice — the visit summary explicitly states "not medical advice.")

## App Review information
- **Contact:** Yew Wee Chua · chuayewwee@gmail.com · _(add phone)_
- **Demo account:** not required (no login).
- **Notes for reviewer:**
  > Personal baby-tracking app, no account/login. The chat assistant runs fully on-device via Apple Intelligence (Apple Foundation Models) — no network needed for inference. Users may optionally select a Gemma model, which triggers a one-time on-device model download from Hugging Face (model weights only; no user data is uploaded). Microphone = voice logging; Calendar = appointment reminders; Photos = attaching baby photos to chat. No data leaves the device.

## Pricing & availability
- **Price:** Free · **IAP:** none · **Territories:** all (or limit to Singapore if preferred)

## Screenshots (required)
- Mandatory size: **iPhone 6.9"** (1320 × 2868, e.g. iPhone 16 Pro Max). Up to 10.
- Suggested shots: Assistant chat (with a logged feed), Feeds tab summary, Visit summary, Growth chart.
- _Claude can capture these on the simulator — ask._

---

## Action items

**Blockers — before submitting:**
1. ✅ Privacy manifest created (`BabyLog/PrivacyInfo.xcprivacy`) — confirmed auto-bundled at `BabyLog.app/PrivacyInfo.xcprivacy`. **Note: build 29 (current TestFlight) predates the manifest — cut a fresh build (30+) for the actual App Store submission.**
2. ⬜ Host `PRIVACY.md` at a public URL → paste as **Privacy Policy URL**.
3. ⬜ Provide a public **Support URL** (make repo public or a simple page).
4. ⬜ Capture screenshots (≥ 6.9").

**Owner-only (off-limits to the agent — do in Xcode/ASC):**
5. ⬜ Fix the **microphone usage string** in project settings — it currently claims *"Audio never leaves your device,"* but the chat mic doesn't force on-device recognition. Either set `requiresOnDeviceRecognition = true` in `SpeechInputPipeline`, or soften the string to *"Speech is transcribed using Apple's Speech Recognition, on-device when available."*
6. ⬜ In ASC: fill App Privacy ("Data Not Collected"), age rating, pricing (Free), attach **build 29**, paste metadata, submit for review.

**Nice to have:**
7. ⬜ Acknowledgements/licenses note for MLX, swift-transformers, swift-huggingface (Apache-2.0/MIT) + Google Gemma Terms (model downloaded at runtime).
8. ⬜ Reconsider the iOS 26.0 floor for public reach (fine for family use).
