#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

developer="$(xcode-select -p)"
framework=""
for candidate in \
    "$developer/Library/Developer/Frameworks" \
    "$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
do
    if [[ -d "$candidate/Testing.framework" ]]; then
        framework="$candidate"
        break
    fi
done

# Ten test files reset HarnessEngine's global caches. Suites run in parallel,
# so one of them can clear a warm cache another is in the middle of measuring —
# an incremental-read test failed once that way, reporting a full re-read, and
# passed on the next three runs. The suite takes under two seconds; running it
# serially costs a little of that and removes the whole class of failure.
PARALLEL=${ANTARIUM_TEST_PARALLEL:-no}
SERIAL=()
[[ "$PARALLEL" == "yes" ]] || SERIAL=(--no-parallel)

if [[ -z "$framework" ]]; then
    exec swift test "${SERIAL[@]}" "$@"
fi

interop="$developer/Library/Developer/usr/lib"
if [[ ! -d "$interop" ]]; then
    interop="$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
fi

exec swift test "${SERIAL[@]}" \
    -Xswiftc -F -Xswiftc "$framework" \
    -Xlinker -F -Xlinker "$framework" \
    -Xlinker -rpath -Xlinker "$framework" \
    -Xlinker -rpath -Xlinker "$interop" \
    "$@"
