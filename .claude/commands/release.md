Release BabyLog to TestFlight via local Fastlane.

Steps:
1. Run `git status --short` to check for uncommitted changes. If any tracked files are modified, stage and commit them with a concise conventional commit message before proceeding.
2. Run `git push origin main` to ensure the remote is up to date.
3. Set the required environment variables:
   ```
   export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/3.4.0/bin:$PATH"
   export ASC_KEY_ID="9QTZ9M5G4Y"
   export ASC_ISSUER_ID="cd786e00-6f3e-4a98-ba23-d4974a8e0876"
   export ASC_KEY_CONTENT=$(base64 -i /Users/yewwee/Downloads/AuthKey_9QTZ9M5G4Y.p8 | tr -d '\n')
   export APP_IDENTIFIER="com.yewwee.BabyLog"
   export APPLE_ID="chuayewwee@gmail.com"
   export TEAM_ID="WPQCQE4HTE"
   export ITC_TEAM_ID="WPQCQE4HTE"
   export MATCH_GIT_URL=""
   export MATCH_PASSWORD=""
   ```
4. Run `bundle exec fastlane beta 2>&1 | tee /tmp/fastlane_release.log; echo "EXIT: ${PIPESTATUS[0]}"` from the repo root (`/Users/yewwee/localdev/BabyLog`). This builds, signs, uploads to TestFlight, waits for Apple to finish processing, and automatically adds the build to the "Internal Testers" group. The full lane takes ~15–25 minutes (build ~5–8 min + Apple processing ~10–15 min).
5. Check the result by running `grep -E "(ARCHIVE SUCCEEDED|EXPORT SUCCEEDED|Successfully uploaded|fastlane finished|EXIT)" /tmp/fastlane_release.log | tail -10`.
6. Report success or, if there was a failure, show the relevant error lines and fix them.
