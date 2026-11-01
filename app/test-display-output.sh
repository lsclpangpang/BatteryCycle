#!/bin/sh
# Simulated/readonly checks only: no display changes and no real administrator prompt.
set -eu
cd "$(dirname "$0")"
OUT=.build/display-restriction-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D DISPLAY_RESTRICTIONS_STANDALONE \
    Sources/BatteryCycle/DisplayOutputBackend.swift Sources/BatteryCycle/DisplayRestrictionSession.swift \
    Tests/BatteryCycleTests/DisplayRestrictionSessionTests.swift -o "$OUT/session-checks"
"$OUT/session-checks"
xcrun swiftc -parse-as-library -D DISPLAY_TRANSPORT_STANDALONE \
    Sources/BatteryCycle/DisplayOutputBackend.swift Sources/BatteryCycle/DisplayTransport.swift \
    Tests/BatteryCycleTests/DisplayTransportTests.swift -o "$OUT/transport-checks"
"$OUT/transport-checks"
xcrun swiftc -parse-as-library -D ADVANCED_ACCESS_STANDALONE \
    Sources/BatteryCycle/AdminAuthorization.swift Sources/BatteryCycle/AdvancedAccessController.swift \
    Tests/BatteryCycleTests/AdvancedAccessTests.swift -o "$OUT/access-checks"
"$OUT/access-checks"
xcrun swiftc -parse-as-library -D DISPLAY_RESTRICTION_CONTROLLER_STANDALONE \
    Sources/BatteryCycle/DisplayOutputBackend.swift Sources/BatteryCycle/DisplayTransport.swift \
    Sources/BatteryCycle/NativeDisplayOutputBackend.swift Sources/BatteryCycle/DisplayRestrictionSession.swift \
    Sources/BatteryCycle/FileDisplayRestrictionStore.swift Sources/BatteryCycle/DisplayOutputRestrictionController.swift \
    Tests/BatteryCycleTests/DisplayRestrictionControllerTests.swift -o "$OUT/controller-checks"
"$OUT/controller-checks"
xcrun swiftc -parse-as-library -D DISPLAY_RESTRICTION_STORE_STANDALONE \
    Sources/BatteryCycle/DisplayOutputBackend.swift Sources/BatteryCycle/DisplayRestrictionSession.swift \
    Sources/BatteryCycle/FileDisplayRestrictionStore.swift \
    Tests/BatteryCycleTests/DisplayRestrictionStoreTests.swift -o "$OUT/store-checks"
"$OUT/store-checks"
xcrun swiftc -parse-as-library -D LEGACY_DISPLAY_RECORD_STANDALONE \
    Sources/BatteryCycle/DisplayOutputBackend.swift Sources/BatteryCycle/DisplayRestrictionSession.swift \
    Sources/BatteryCycle/DisplayController.swift \
    Tests/BatteryCycleTests/LegacyDisplayRecordTests.swift -o "$OUT/legacy-record-checks"
"$OUT/legacy-record-checks"
