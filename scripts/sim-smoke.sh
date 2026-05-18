#!/usr/bin/env bash
#
# sim-smoke.sh — one-shot boot + build + install + launch for LittleE.
#
# Usage:
#   scripts/sim-smoke.sh                 # build Debug, install, launch
#   scripts/sim-smoke.sh --rebuild       # force clean rebuild first
#   scripts/sim-smoke.sh --device "iPhone 16 Pro"   # pick a different sim
#
# On success, writes the booted simulator's UDID to /tmp/littleE-udid
# and prints it to stdout. Subsequent idb/simctl calls can use it as:
#
#   UDID=$(cat /tmp/littleE-udid)
#   xcrun simctl io "$UDID" screenshot /tmp/step.png
#   idb ui tap --udid "$UDID" 200 500
#
# Exit codes: 0 = app launched; 1 = any step failed.

set -euo pipefail

DEVICE="iPhone 16"
REBUILD=0
BUNDLE_ID="com.yewwee.LittleE"
SCHEME="LittleE"
PROJECT="LittleE.xcodeproj"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --rebuild) REBUILD=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

echo "==> Booting '$DEVICE'"
UDID=$(xcrun simctl list devices available -j \
    | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['name'] == '$DEVICE':
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" || true)

if [[ -z "$UDID" ]]; then
    echo "no simulator named '$DEVICE' found. run: xcrun simctl list devices" >&2
    exit 1
fi

echo "$UDID" > /tmp/littleE-udid
echo "    UDID: $UDID"

# Boot if not already booted (simctl boot is idempotent-ish but spams
# errors when already booted, so we check first).
STATE=$(xcrun simctl list devices -j | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['udid'] == '$UDID':
            print(d['state'])
            sys.exit(0)
")
if [[ "$STATE" != "Booted" ]]; then
    xcrun simctl boot "$UDID"
fi
open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true

if [[ $REBUILD -eq 1 ]]; then
    echo "==> Clean build"
    xcodebuild clean -project "$PROJECT" -scheme "$SCHEME" >/dev/null
fi

echo "==> Building Debug for simulator"
DERIVED=$(mktemp -d)
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -5

APP_PATH=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 2 -name "LittleE.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "build succeeded but couldn't find LittleE.app under $DERIVED" >&2
    exit 1
fi
echo "    .app: $APP_PATH"

echo "==> Installing"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"

echo "==> Launching"
# Pull Claude API key from the developer's login Keychain (if present) and
# forward it to the app process via SIMCTL_CHILD_* so LittleEApp's DEBUG hook
# can migrate it into the app Keychain. The value is captured directly into
# the env block and never echoed — don't add `echo`s around this section.
# Match by service only — the owner's login keychain entry may have been
# created with any account label (e.g. empty, "anthropic", or the user name).
# Filtering on `-a "$USER"` previously caused silent misses that launched the
# app with an empty env var; see .agents/bug-reports/2026-04-13-claude-tool-call-smoke.md.
CLAUDE_KEY=$(security find-generic-password -s LittleE-claude -w ~/Library/Keychains/login.keychain-db 2>/dev/null || true)
if [[ -n "$CLAUDE_KEY" ]]; then
    echo "    forwarding LittleE-claude key via SIMCTL_CHILD_LITTLEE_CLAUDE_API_KEY (${#CLAUDE_KEY} chars)"
    env SIMCTL_CHILD_LITTLEE_CLAUDE_API_KEY="$CLAUDE_KEY" \
        xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
else
    echo "    (no LittleE-claude key in login Keychain — Claude backend will prompt)" >&2
    echo "    hint: security add-generic-password -s LittleE-claude -a \"\$USER\" -w <key>" >&2
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
fi
unset CLAUDE_KEY

# Give the launch screen a moment so the first screenshot lands on UI
# not black pixels.
sleep 1

echo "==> Ready. UDID written to /tmp/littleE-udid"
echo "$UDID"
