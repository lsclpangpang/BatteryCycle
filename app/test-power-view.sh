#!/bin/sh
set -eu
cd "$(dirname "$0")"
OUT=.build/power-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D POWER_FLOW_STANDALONE \
    Sources/BatteryCycle/PowerTelemetry.swift \
    Sources/BatteryCycle/PortReader.swift Sources/BatteryCycle/PowerFlowView.swift \
    Tests/BatteryCycleTests/PowerFlowPresentationTests.swift -o "$OUT/view-checks"
"$OUT/view-checks"
