#!/bin/sh
set -eu
cd "$(dirname "$0")"
OUT=.build/menu-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D MENU_SIZING_STANDALONE \
    Sources/BatteryCycle/MenuSizing.swift \
    Tests/BatteryCycleTests/MenuSizingTests.swift -o "$OUT/sizing-checks"
"$OUT/sizing-checks"
