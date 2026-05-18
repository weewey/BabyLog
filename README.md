# LittleE

Native iOS app to track baby Ethan — milk intake, growth, diapers, photos, medical appointments, and developmental milestones.

Built and maintained by a team of managed Claude agents (PM, FE, BE, Reviewer, Security, Tester) against a sprint board.

## Stack
- SwiftUI (iOS)
- CloudKit (two-device sync: user + wife)
- XCTest for unit + UI tests
- Fastlane → TestFlight
- GitHub Actions (CI + release)

## Local dev
Open `LittleE.xcodeproj` in Xcode, pick an iPhone simulator, ⌘U to run tests.

## CI
- Every PR: `xcodebuild test` on macOS runner
- Merge to `main`: auto-upload to TestFlight via Fastlane

## Secrets / vars required in GitHub
Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` (base64 .p8), optionally `MATCH_GIT_URL` + `MATCH_PASSWORD`.
Vars: `APP_IDENTIFIER`, `APPLE_ID`, `ITC_TEAM_ID`, `TEAM_ID`.
