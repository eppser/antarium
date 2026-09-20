#!/bin/bash
# Everything that has to hold before a change is finished.
#
# AGENTS.md names three commands; this runs those and the checks that were
# being reassembled by hand each time — a fresh install through the real app
# path, the command line on a machine that has never run it, every shipped
# harness through --check, and the scan benchmark.
#
# Nothing here touches your own settings: every step that writes runs under
# ANTARIUM_HOME in a temporary directory.
set -uo pipefail
cd "$(dirname "$0")"

fails=0
step() { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok  %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; fails=$((fails + 1)); }

BIN=.build/debug/Antarium
APP=dist/Antarium.app/Contents/MacOS/Antarium

step "Tests"
if ./test.sh >/tmp/verify-tests.log 2>&1; then
    ok "$(grep -oE 'Test run with [0-9]+ tests' /tmp/verify-tests.log | tail -1)"
else
    bad "test suite — see /tmp/verify-tests.log"
fi

step "Tests on a machine where Antarium has never run"
# CI checks out a fresh copy and has no ~/.antarium. A test that reads the
# user's seeded harnesses passes here and fails there, which is how the remote
# tmux tests sat red in CI while green on the machine that wrote them.
bare=$(mktemp -d)
if ANTARIUM_HOME="$bare" ./test.sh >/tmp/verify-bare.log 2>&1; then
    ok "$(grep -oE 'Test run with [0-9]+ tests' /tmp/verify-bare.log | tail -1)"
else
    bad "test suite depends on local state — see /tmp/verify-bare.log"
    grep -E '^✘ Test "' /tmp/verify-bare.log | head -3
fi
rm -rf "$bare"

# Package.swift excludes `dist` only when it exists, because SwiftPM warns
# about an exclude that names nothing. SwiftPM also caches the evaluated
# manifest, so that condition is frozen at whatever was true last time — and a
# run that removes dist then builds gets "Invalid Exclude: File not found".
# Making the directory before any build keeps the cached answer true.
mkdir -p dist

step "Strict concurrency"
out=$(swift build --scratch-path /tmp/antarium-strict \
        -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency 2>&1)
if printf '%s' "$out" | grep -qE 'error:|warning:'; then
    bad "strict build reported diagnostics"
    printf '%s\n' "$out" | grep -E 'error:|warning:' | head -5
else
    ok "clean"
fi

step "Release build"
if ./build.sh >/tmp/verify-build.log 2>&1; then ok "dist/Antarium.app"
else bad "build.sh — see /tmp/verify-build.log"; fi

step "Descriptor verification"
# Against the built app as well as the debug binary. They do not carry
# resources the same way: the app is assembled by copying named directories,
# so a resource that reaches the SwiftPM bundle can be missing from the thing
# that actually ships. Checking only the debug binary hid exactly that.
for runner in "$BIN" "$APP"; do
    label=$([ "$runner" = "$BIN" ] && echo debug || echo app)
    if [ ! -x "$runner" ]; then bad "$label binary missing"; continue; fi
    for c in --verify-harness-quota --verify-harness-fixtures --verify-harness-installations; do
        if "$runner" "$c" >/tmp/verify-$$.log 2>&1
        then ok "$label $c ($(grep -c '^✓' /tmp/verify-$$.log) passed)"
        else bad "$label $c"; grep '^✗' /tmp/verify-$$.log | head -3; fi
    done
done
rm -f /tmp/verify-$$.log

step "Every shipped harness checks clean"
dirty=0
for h in Resources/harnesses/*.json; do
    "$BIN" --check "$h" 2>&1 | grep -q "0 problem" || { bad "--check $(basename "$h")"; dirty=1; }
done
[ $dirty -eq 0 ] && ok "$(ls Resources/harnesses/*.json | wc -l | tr -d ' ') harnesses"

step "Command line on a machine that has never run it"
for flag in --agents --status --detect-agents; do
    home=$(mktemp -d)
    ANTARIUM_HOME="$home" "$BIN" "$flag" >/dev/null 2>&1
    n=$(ls "$home"/harnesses/*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && ok "$flag seeded $n harnesses" || bad "$flag seeded nothing"
    rm -rf "$home"
done

step "First run through the real app path"
if [ -x "$APP" ]; then
    home=$(mktemp -d)
    ANTARIUM_HOME="$home" "$APP" >/dev/null 2>&1 & pid=$!
    sleep 11; kill $pid 2>/dev/null; wait $pid 2>/dev/null
    chosen=$(python3 -c "
import json,sys
try: print(','.join(json.load(open('$home/config.json')).get('enabledAgents') or []))
except Exception: print('')" 2>/dev/null)
    [ -n "$chosen" ] && ok "detected and enabled: $chosen" || bad "first run enabled nothing"
    rm -rf "$home"
else
    bad "no built app at $APP"
fi

step "Scan benchmark"
home=$(mktemp -d); mkdir -p "$home/harnesses"; cp Resources/harnesses/*.json "$home/harnesses/"
ANTARIUM_HOME="$home" "$BIN" --bench >/dev/null 2>&1
ANTARIUM_HOME="$home" "$BIN" --bench 2>&1 | sed 's/^/   /'
behind=$(python3 -c "
import json
try:
    d=json.load(open('$home/transcripts-v6.json'))
    print(sum(1 for v in d.values() if v.get('backlog')))
except Exception: print(0)")
[ "$behind" -gt 0 ] && printf '   note %s transcript(s) still catching up — these are throughput, not steady state\n' "$behind"
rm -rf "$home"

printf '\n'
[ $fails -eq 0 ] && { echo "All checks passed."; exit 0; }
echo "$fails check(s) failed."; exit 1
