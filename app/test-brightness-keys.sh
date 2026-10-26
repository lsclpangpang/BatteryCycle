#!/bin/sh
# Pure event-decoding checks. Does not install an input monitor or change brightness.
set -eu
cd "$(dirname "$0")"
OUT=.build/brightness-key-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D BRIGHTNESS_KEY_STANDALONE \
    Sources/BatteryCycle/NativeBrightnessKeyMonitor.swift \
    Tests/BatteryCycleTests/NativeBrightnessKeyMonitorTests.swift \
    -o "$OUT/brightness-key-checks"
"$OUT/brightness-key-checks"
