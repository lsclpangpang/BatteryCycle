#!/bin/sh
set -eu
cd "$(dirname "$0")"
OUT=.build/battery-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D BATTERY_READINGS_STANDALONE \
    Sources/BatteryCycle/BatteryReadings.swift \
    Tests/BatteryCycleTests/BatteryReadingsTests.swift -o "$OUT/reading-checks"
"$OUT/reading-checks"
