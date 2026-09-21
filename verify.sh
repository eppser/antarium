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

# A suite that ran no tests exits zero, and `ok "$(grep …)"` would report that
# as a blank pass. Every test step below reports the count it actually saw and
# refuses a run that saw none — the same rule as the descriptor verifiers.
ran() {   # ran <logfile> <label>
    local n
    n=$(grep -oE 'Test run with [0-9]+ tests' "$1" | tail -1 | grep -oE '[0-9]+')
    if [ -n "$n" ] && [ "$n" -gt 0 ]; then ok "$n tests $2"; return 0; fi
    bad "no tests ran $2 — see $1"; return 1
}

step "Tests"
if ./test.sh >/tmp/verify-tests.log 2>&1; then
    ran /tmp/verify-tests.log ""
else
    bad "test suite — see /tmp/verify-tests.log"
fi

step "Tests on a machine where Antarium has never run"
# CI checks out a fresh copy and has no ~/.antarium. A test that reads the
# user's seeded harnesses passes here and fails there, which is how the remote
# tmux tests sat red in CI while green on the machine that wrote them.
bare=$(mktemp -d)
if ANTARIUM_HOME="$bare" ./test.sh >/tmp/verify-bare.log 2>&1; then
    ran /tmp/verify-bare.log "on a bare machine"
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

step "Tests in a timezone that is not UTC"
# CI runners are UTC, and so a date bug that reads timestamps in the local
# zone is invisible there. Interpreting ISO timestamps locally instead of as
# UTC passes every test under TZ=UTC and fails two thousand of them under a
# half-hour offset. Kolkata is +05:30 deliberately: a whole-hour zone would
# miss an error that happens to be a multiple of an hour.
if TZ=Asia/Kolkata ./test.sh >/tmp/verify-tz.log 2>&1; then
    ran /tmp/verify-tz.log "(TZ=Asia/Kolkata)"
else
    bad "test suite depends on the local timezone — see /tmp/verify-tz.log"
    grep -E '^✘ Test "' /tmp/verify-tz.log | head -3
fi

step "Mutation catalogue still applies"
# Every entry has been confirmed to fail a test, but only against the code as
# it was then. A rewrite can leave one matching nothing, and mutate.sh only
# says so during a full run, which takes hours.
if out=$(python3 tools/check-mutations.py mutations.txt 2>&1); then
    printf '%s\n' "$out" | tail -1
else
    bad "mutations.txt has entries that no longer apply"
    printf '%s\n' "$out" | grep FAIL | head -5
fi

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
# A verifier that checks nothing exits zero. "0 passed" was reported as ok,
# so a build that shipped no descriptors at all would have gone out green —
# which is the very failure the paragraph above describes. Two rules now: the
# count must be above zero, and the app must verify exactly as many as the
# debug binary. The second is self-maintaining, because adding a descriptor
# raises both numbers without touching this script.
declare -a counts=()
for runner in "$BIN" "$APP"; do
    label=$([ "$runner" = "$BIN" ] && echo debug || echo app)
    if [ ! -x "$runner" ]; then bad "$label binary missing"; continue; fi
    for c in --verify-harness-quota --verify-harness-fixtures --verify-harness-installations; do
        if "$runner" "$c" >/tmp/verify-$$.log 2>&1; then
            n=$(grep -c '^✓' /tmp/verify-$$.log)
            counts+=("$label $c $n")
            if [ "$n" -gt 0 ]
            then ok "$label $c ($n passed)"
            else bad "$label $c verified nothing — a check that checks nothing exits zero"; fi
        else bad "$label $c"; grep '^✗' /tmp/verify-$$.log | head -3; fi
    done
done
rm -f /tmp/verify-$$.log
for c in --verify-harness-quota --verify-harness-fixtures --verify-harness-installations; do
    d=$(printf '%s\n' "${counts[@]}" | awk -v c="$c" '$1=="debug" && $2==c {print $3}')
    a=$(printf '%s\n' "${counts[@]}" | awk -v c="$c" '$1=="app"   && $2==c {print $3}')
    if [ -n "$d" ] && [ -n "$a" ] && [ "$d" != "$a" ]; then
        bad "$c: debug verified $d, the app verified $a — a resource did not reach the bundle"
    fi
done

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

# The unconfigured state exists only on a machine that has never run this.
# `Config` binds its file path at first touch, so a test process that has
# already read a real config cannot get back to it — which is why the default
# for `enabledAgents` went from empty to a fixed list of three and back with
# no test objecting.
step "A machine that has never run it has chosen nothing"
home=$(mktemp -d)
out=$(ANTARIUM_HOME="$home" "$BIN" --detect-agents 2>&1)
if printf '%s' "$out" | grep -q "recorded   nothing yet"; then
    ok "no recorded choice"
else
    bad "a never-run machine reports a recorded choice"
fi
# And the first run writes one rather than assuming it.
out=$(ANTARIUM_HOME="$home" "$BIN" --detect-agents --apply 2>&1)
printf '%s' "$out" | grep -q "^wrote      enabledAgents = " \
    && ok "first run recorded its choice" || bad "first run wrote nothing"
# A second run leaves it alone: this is the whole of "the user's choice wins".
out=$(ANTARIUM_HOME="$home" "$BIN" --detect-agents --apply 2>&1)
printf '%s' "$out" | grep -q "wrote      nothing" \
    && ok "a recorded choice is left alone" || bad "a second run rewrote the choice"
rm -rf "$home"

step "First run through the real app path"
if [ -x "$APP" ]; then
    home=$(mktemp -d)
    ANTARIUM_HOME="$home" "$APP" >/dev/null 2>&1 & pid=$!
    # Wait for the thing being checked rather than for a fixed time. A busy
    # machine took longer than the eleven seconds this used to sleep, which
    # failed the step for a reason that had nothing to do with the app.
    for _ in $(seq 1 40); do
        [ -s "$home/config.json" ] && grep -q enabledAgents "$home/config.json" 2>/dev/null && break
        sleep 1
    done
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
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
# --bench reports the harness count it measured and whether transcripts are
# still being absorbed, so there is nothing to recompute here.
ANTARIUM_HOME="$home" "$BIN" --bench 2>&1 | sed 's/^/   /'
rm -rf "$home"

printf '\n'
[ $fails -eq 0 ] && { echo "All checks passed."; exit 0; }
echo "$fails check(s) failed."; exit 1
