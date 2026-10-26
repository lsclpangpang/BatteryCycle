#!/bin/sh
# Real process/file-lock checks; never accesses display hardware or input permissions.
set -eu
cd "$(dirname "$0")"
OUT="$(pwd)/.build/brightness-lease-checks"
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D BRIGHTNESS_LEASE_HELPER \
    Sources/BatteryCycle/BrightnessControlLease.swift \
    Tests/BatteryCycleTests/BrightnessControlLeaseTests.swift \
    -o "$OUT/lease-helper"
xcrun swiftc -parse-as-library -D BRIGHTNESS_LEASE_STANDALONE \
    Sources/BatteryCycle/BrightnessControlLease.swift \
    Tests/BatteryCycleTests/BrightnessControlLeaseTests.swift \
    -o "$OUT/lease-checks"
BATTERYCYCLE_BRIGHTNESS_LEASE_HELPER="$OUT/lease-helper" "$OUT/lease-checks"
