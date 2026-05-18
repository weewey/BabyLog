#!/bin/bash
set -euo pipefail

# Automated test runner for LittleE
# Usage: ./scripts/run_tests.sh [--unit-only | --ui-only | --all]

MODE="${1:---all}"

echo "=== LittleECore (Linux-compatible, fast) ==="
swift test --package-path LittleECore 2>&1

SIM=$(xcrun simctl list devices available --json | python3 -c "
import json, sys
data = json.load(sys.stdin)['devices']
for rt, devs in data.items():
    if 'iOS' in rt:
        for d in devs:
            if d['name'].startswith('iPhone'):
                print(d['name']); sys.exit(0)
")
echo "Using simulator: $SIM"

if [[ "$MODE" == "--unit-only" ]]; then
    echo "=== Unit tests (iOS) ==="
    xcodebuild test \
        -project LittleE.xcodeproj \
        -scheme LittleE \
        -destination "platform=iOS Simulator,name=$SIM" \
        -skip-testing:LittleEUITests \
        CODE_SIGNING_ALLOWED=NO \
        IPHONEOS_DEPLOYMENT_TARGET=18.0 \
        2>&1 | xcpretty
elif [[ "$MODE" == "--ui-only" ]]; then
    echo "=== UI tests ==="
    xcodebuild test \
        -project LittleE.xcodeproj \
        -scheme LittleE \
        -destination "platform=iOS Simulator,name=$SIM" \
        -only-testing:LittleEUITests \
        CODE_SIGNING_ALLOWED=NO \
        IPHONEOS_DEPLOYMENT_TARGET=18.0 \
        2>&1 | xcpretty
else
    echo "=== All tests (unit + UI) ==="
    xcodebuild test \
        -project LittleE.xcodeproj \
        -scheme LittleE \
        -destination "platform=iOS Simulator,name=$SIM" \
        CODE_SIGNING_ALLOWED=NO \
        IPHONEOS_DEPLOYMENT_TARGET=18.0 \
        -resultBundlePath TestResults.xcresult \
        2>&1 | xcpretty
fi

echo "=== All tests passed ==="
