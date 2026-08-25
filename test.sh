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

if [[ -z "$framework" ]]; then
    exec swift test "$@"
fi

interop="$developer/Library/Developer/usr/lib"
if [[ ! -d "$interop" ]]; then
    interop="$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$framework" \
    -Xlinker -F -Xlinker "$framework" \
    -Xlinker -rpath -Xlinker "$framework" \
    -Xlinker -rpath -Xlinker "$interop" \
    "$@"
