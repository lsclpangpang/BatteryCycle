#!/bin/sh
# Mock authorization and host lifecycle only; no password prompt or display changes.
set -eu
cd "$(dirname "$0")"
OUT=.build/menu-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D MENU_NAVIGATION_STANDALONE \
    Sources/BatteryCycle/AdminAuthorization.swift Sources/BatteryCycle/AdvancedAccessController.swift \
    Sources/BatteryCycle/MenuNavigationController.swift \
    Tests/BatteryCycleTests/MenuNavigationTests.swift -o "$OUT/navigation-checks"
"$OUT/navigation-checks"
