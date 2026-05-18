Create a GitHub release tag to trigger the TestFlight CI pipeline.

Steps:
1. Run `git tag --sort=-creatordate | head -5` to see existing tags
2. Generate the tag name using PST timezone: `TZ=America/Los_Angeles date '+release-%Y%m%d-%H%M'`
3. Run `git log $(git tag --sort=-creatordate | head -1)..HEAD --oneline` to gather changes since the last release
4. Create the release with `gh release create <tag> --target main --title "<tag>" --notes "<changelog>"` where the changelog summarizes the commits since the last release tag
5. Print the release URL so the user can track it
