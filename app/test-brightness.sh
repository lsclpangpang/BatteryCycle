#!/bin/sh
# Pure state-machine checks; never changes the display or system settings.
set -eu
cd "$(dirname "$0")"
OUT=.build/brightness-checks
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -D BRIGHTNESS_STANDALONE \
    Sources/BatteryCycle/BrightnessSession.swift Tests/BatteryCycleTests/BrightnessSessionTests.swift \
    -o "$OUT/brightness-checks"
"$OUT/brightness-checks"

xcrun swiftc -parse-as-library -D BRIGHTNESS_STORE_STANDALONE \
    Sources/BatteryCycle/BrightnessSession.swift Sources/BatteryCycle/FileBrightnessRecoveryStore.swift \
    Tests/BatteryCycleTests/BrightnessRecoveryStoreTests.swift -o "$OUT/store-checks"
"$OUT/store-checks"

xcrun swiftc -parse-as-library -D BRIGHTNESS_CONTROLLER_STANDALONE \
    Sources/BatteryCycle/BrightnessSession.swift Sources/BatteryCycle/FileBrightnessRecoveryStore.swift \
    Sources/BatteryCycle/NativeBrightnessBackend.swift Sources/BatteryCycle/NativeBrightnessEvents.swift \
    Sources/BatteryCycle/NativeBrightnessKeyMonitor.swift \
    Sources/BatteryCycle/BrightnessControlLease.swift \
    Sources/BatteryCycle/BrightnessRestoreShortcut.swift Sources/BatteryCycle/BrightnessController.swift \
    Tests/BatteryCycleTests/BrightnessControllerTests.swift -o "$OUT/controller-checks"
"$OUT/controller-checks"

xcrun swiftc -parse-as-library -D BRIGHTNESS_SHORTCUT_STANDALONE \
    Sources/BatteryCycle/BrightnessRestoreShortcut.swift \
    Tests/BatteryCycleTests/BrightnessRestoreShortcutTests.swift -o "$OUT/shortcut-checks"
"$OUT/shortcut-checks"

sh ./test-brightness-keys.sh
sh ./test-brightness-lease.sh
