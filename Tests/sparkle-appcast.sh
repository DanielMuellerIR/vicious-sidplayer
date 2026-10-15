#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/vicious-sparkle-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc scripts/verify-appcast.swift -o "$work/verify-appcast"
swift Tests/SparkleAppcastTests.swift "$work/verify-appcast" "$work"
