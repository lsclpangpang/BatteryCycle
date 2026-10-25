#!/bin/sh
# Read-only power decoding checks; also works with Command Line Tools alone.
set -eu
cd "$(dirname "$0")"
OUT=.build/power-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D POWER_TELEMETRY_STANDALONE \
    Sources/BatteryCycle/PowerTelemetry.swift Tests/BatteryCycleTests/PowerTelemetryTests.swift \
    -o "$OUT/power-checks"
"$OUT/power-checks"
