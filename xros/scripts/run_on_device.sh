#!/bin/bash
# visionOS spike: starts Henge on an Apple Vision Pro with JIT. The app is launched stopped, lldb attaches,
# xros/lldb/henge_jit.py hands out the JIT region, and lldb detaches: the app keeps running on its own.
#
# Usage: xros/scripts/run_on_device.sh DEVICE [BUNDLE_ID] [CODE_CACHE_MB]
#   DEVICE         the Vision Pro's identifier or name (xcrun devicectl list devices)
#   BUNDLE_ID      what the app was signed as (default com.henge.app)
#   CODE_CACHE_MB  512, 1024 or 1536 (default 512: every page of it costs a round trip to the device)
# The app must be installed already, built from the HengeVision target with a development signature.
set -euo pipefail
DEVICE="${1:?usage: $0 DEVICE [BUNDLE_ID] [CODE_CACHE_MB]}"
BUNDLE="${2:-com.henge.app}"
CACHE="${3:-512}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --start-stopped \
    --environment-variables '{"HENGE_JIT_SERVICER":"1"}' --json-output "$WORK/launch.json" \
    "$BUNDLE" -henge.perf.codeCacheMB "<integer>$CACHE</integer>" >/dev/null
PID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['result']['process']['processIdentifier'])" "$WORK/launch.json")"
echo "Henge started stopped, pid $PID; attaching lldb"

export HENGE_JIT_DETACH=1 HENGE_JIT_LOG="${HENGE_JIT_LOG:-$WORK/progress.txt}"
xcrun lldb --batch -o "device select $DEVICE" -o "device process attach --pid $PID" \
    -o "command script import $ROOT/xros/lldb/henge_jit.py" -o "target stop-hook add -P henge_jit.Servicer" \
    -o "henge_wait" 2>&1 | grep -E "henge-jit.py|henge_wait|error" || true
