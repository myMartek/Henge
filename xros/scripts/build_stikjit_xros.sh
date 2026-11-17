#!/bin/bash
# visionOS spike: builds StikJIT (MPL-2.0, github.com/StikDebug/StikJIT) and Henge's pairing library (xros/tools/henge-pair)
# for visionOS, for the built-in JIT helper: JIT without a Mac attached.
#   - StikJIT ships libidevice_ffi.a for iOS and tvOS only, and Rust's visionOS target needs a nightly toolchain, so
#     both Rust libraries are the iOS builds with their objects' platform rewritten (retag_static_lib.sh).
#   - StikJIT's checkout needs the StikJIT-visionOS target this spike adds to its project.yml:
#     git -C ../StikJIT apply ../Henge/xros/patches/stikjit-visionos.patch   (made against StikJIT a9ccad9)
# Usage: xros/scripts/build_stikjit_xros.sh [STIKJIT_CHECKOUT]     (default: ../StikJIT)
# Output: ios/deps/StikJIT-visionOS.xcframework, xros/deps/<platform>/lib/{libidevice_ffi,libhenge_rpclient}.a
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STIKJIT="$(cd "${1:-$ROOT/../StikJIT}" && pwd)"

( cd "$ROOT/xros/tools/henge-pair" && IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --lib --target aarch64-apple-ios )
for platform in xros xrsimulator; do
    "$ROOT/xros/scripts/retag_static_lib.sh" "$STIKJIT/idevice/libidevice_ffi.a" "$ROOT/xros/deps/$platform/lib/libidevice_ffi.a" "$platform"
    "$ROOT/xros/scripts/retag_static_lib.sh" "$ROOT/xros/tools/henge-pair/target/aarch64-apple-ios/release/libhenge_rpclient.a" \
        "$ROOT/xros/deps/$platform/lib/libhenge_rpclient.a" "$platform"
    rm -f "$ROOT/xros/deps/$platform/lib/libhusk_rppairing.a" # an earlier state of this spike linked Husk's
done

cd "$STIKJIT"
xcodegen generate >/dev/null
rm -rf build/StikJIT-xros.xcarchive build/StikJIT-xrsimulator.xcarchive
for pair in "xros:generic/platform=visionOS" "xrsimulator:generic/platform=visionOS Simulator"; do
    xcodebuild archive -project StikJIT.xcodeproj -scheme StikJIT-visionOS -destination "${pair#*:}" \
        -archivePath "build/StikJIT-${pair%%:*}" SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
        ARCHS=arm64 HENGE_XROS_DEPS="$ROOT/xros/deps" 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
done
rm -rf "$ROOT/ios/deps/StikJIT-visionOS.xcframework"
mkdir -p "$ROOT/ios/deps"
xcodebuild -create-xcframework \
    -framework build/StikJIT-xros.xcarchive/Products/Library/Frameworks/StikJIT.framework \
    -framework build/StikJIT-xrsimulator.xcarchive/Products/Library/Frameworks/StikJIT.framework \
    -output "$ROOT/ios/deps/StikJIT-visionOS.xcframework"
ls "$ROOT/ios/deps/StikJIT-visionOS.xcframework"
