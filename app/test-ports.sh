#!/bin/sh
# Command Line Tools 也能运行；不要求安装完整 Xcode / XCTest。
set -eu
cd "$(dirname "$0")"
OUT=.build/port-checks
mkdir -p "$OUT"

xcrun swiftc -parse-as-library -D PORT_READER_STANDALONE \
    Sources/BatteryCycle/PortReader.swift Tests/BatteryCycleTests/PortReaderTests.swift \
    -o "$OUT/reader-checks"
"$OUT/reader-checks"

xcrun swiftc -parse-as-library -D PORT_MONITOR_STANDALONE \
    Sources/BatteryCycle/PortReader.swift Sources/BatteryCycle/PortMonitor.swift \
    Sources/BatteryCycle/PowerTelemetry.swift \
    Tests/BatteryCycleTests/PortMonitorTests.swift -o "$OUT/monitor-checks"
"$OUT/monitor-checks"
