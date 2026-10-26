#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/batteryd-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
xcrun clang -O1 -g -Wall -Wextra -Werror \
    -DBATTERYD_TEST_DIR="\"$TEST_DIR\"" \
    tests/batteryd_sleep_test.c -framework IOKit -framework CoreFoundation \
    -o "$TEST_DIR/batteryd-sleep-tests"
"$TEST_DIR/batteryd-sleep-tests"
