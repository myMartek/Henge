#!/bin/bash
# visionOS spike: type-checks the app's Swift sources against the visionOS SDK without building anything else.
# Usage: xros/scripts/typecheck_xros.sh [xros|xrsimulator]
set -uo pipefail
cd "$(dirname "$0")/../.."
P="${1:-xrsimulator}"
T="arm64-apple-xros2.0"; [ "$P" = xrsimulator ] && T="$T-simulator"
SDK="$(xcrun --sdk "$P" --show-sdk-path)"
SOURCES=()
while IFS= read -r s; do SOURCES+=("$s"); done < <(find ios/Henge -name '*.swift' -print | sort)
SOURCES+=(ios/HengeJITHelper/HengeJITMessages.swift)
xcrun --sdk "$P" swiftc -typecheck -target "$T" -sdk "$SDK" -swift-version 5 \
    -import-objc-header ios/Henge/HengeBridge.h -Xcc -Icore -Xcc -Ihost -Xcc -Idevices "${SOURCES[@]}" 2>&1 \
    | grep -E "^ios/.*(error|warning: .*unavailable)" | sort -u
