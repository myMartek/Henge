#!/bin/bash
# visionOS spike: makes a visionOS copy of a static library built for iOS arm64, by rewriting each object's
# platform (LC_BUILD_VERSION). The code is the same for both: same CPU, same calling convention, same libSystem.
# For libraries whose visionOS build is not at hand (StikJIT's prebuilt libidevice_ffi.a, Husk's Rust pairing
# library: Rust's visionOS target needs a nightly toolchain and a std built from source).
#
# Usage: xros/scripts/retag_static_lib.sh IN.a OUT.a xros|xrsimulator [MINOS]
set -euo pipefail
IN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; OUT="$2"; PLATFORM="$3"; MINOS="${4:-2.0}"
case "$PLATFORM" in xros) NUMBER=11 ;; xrsimulator) NUMBER=12 ;; *) echo "platform: xros or xrsimulator" >&2; exit 2 ;; esac
SDKVER="$(xcrun --sdk "$PLATFORM" --show-sdk-version)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out" "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
# Members can share a name, so they are taken out by position. vtool cannot rewrite an object file's build version
# ("not enough space to hold load commands"), so the three fields are set in place: same size, nothing moves.
python3 - "$IN" "$WORK/out" "$NUMBER" "$MINOS" "$SDKVER" <<'PY'
import os, struct, sys
path, out, platform = sys.argv[1], sys.argv[2], int(sys.argv[3])

def version(text):
    parts = [int(x) for x in (text.split(".") + ["0", "0"])[:3]]
    return parts[0] << 16 | parts[1] << 8 | parts[2]

minos, sdk = version(sys.argv[4]), version(sys.argv[5])
LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS, LC_SOURCE_VERSION = 0x32, 0x25, 0x2A

def retag(body):
    """The object with its platform set, or None if it is not a 64-bit Mach-O object that names one.
    LC_BUILD_VERSION is rewritten in place. The older LC_VERSION_MIN_IPHONEOS (Rust's prebuilt std uses it) has no
    visionOS form and is 8 bytes shorter than LC_BUILD_VERSION, so it becomes an LC_SOURCE_VERSION of the same
    size: the object then names no platform, and the linker takes it for any."""
    if len(body) < 32 or struct.unpack_from("<I", body, 0)[0] != 0xFEEDFACF:
        return None
    ncmds = struct.unpack_from("<I", body, 16)[0]
    data, offset, found = bytearray(body), 32, False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_BUILD_VERSION:
            struct.pack_into("<III", data, offset + 8, platform, minos, sdk)
            found = True
        elif cmd == LC_VERSION_MIN_IPHONEOS and size == 16:
            struct.pack_into("<IIQ", data, offset, LC_SOURCE_VERSION, 16, 0)
            found = True
        offset += size
    return bytes(data) if found else None

data = open(path, "rb").read()
assert data[:8] == b"!<arch>\n", "not an ar archive"
pos, count, tagged = 8, 0, 0
while pos + 60 <= len(data):
    header = data[pos:pos + 60]
    name = header[:16].decode().strip()
    size = int(header[48:58].decode().strip())
    body = data[pos + 60:pos + 60 + size]
    if name.startswith("#1/"):                       # BSD long name: stored before the contents
        length = int(name[3:])
        name = body[:length].rstrip(b"\0").decode()
        body = body[length:]
    if not name.startswith("__.SYMDEF"):
        count += 1
        new = retag(body)
        tagged += new is not None
        open(os.path.join(out, "%05d_%s" % (count, os.path.basename(name) or "member")), "wb").write(new or body)
    pos += 60 + size + (size & 1)
print("%d members, %d objects retagged, %d left as they were (no platform named)" % (count, tagged, count - tagged))
PY
rm -f "$OUT"
xcrun --sdk "$PLATFORM" libtool -static -no_warning_for_no_symbols -o "$OUT" "$WORK/out"/* 2>&1 | grep -v "same member name\|has no symbols\|is not an object file" || true
echo "$OUT for $PLATFORM $MINOS"
