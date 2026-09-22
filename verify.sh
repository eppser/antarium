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

# A harness that maps no context at all must not be reported as having an
# empty one. --check is the tool a descriptor author uses to find out whether
# their mapping works, and "context=0" told them it does when nothing was
# read. A harness that *does* map one and measures zero is a different thing
# and keeps its zero, so only the harnesses declaring no mapping are checked.
invented=0 checked=0
for h in Resources/harnesses/*.json; do
    python3 -c "
import json,sys
m = json.load(open('$h')).get('map') or {}
sys.exit(0 if m.get('contextTokens') else 1)" && continue
    checked=$((checked+1))
    if "$BIN" --check "$h" 2>&1 | grep -q "context=0 "; then
        bad "--check $(basename "$h") reports a context it never mapped"
        invented=1
    fi
done
[ $checked -gt 0 ] || bad "no harness without a context mapping — the check proved nothing"
[ $invented -eq 0 ] && [ $checked -gt 0 ] \
    && ok "$checked harness(es) mapping no context report none"

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
# The settings directory holds API keys now, and on macOS every local account
# is in `staff`. A home directory at 0750 is traversable by all of them, so a
# key in a 0755 folder is readable by any other user of the Mac.
# A folder that already exists is the case a first run cannot show. One made
# by a version that predates the securing — or by hand — stayed exactly as it
# was, because only the menu bar app tightened it and the command line never
# did. The setup hints send people to put keys in there.
step "An existing settings directory is tightened, not just a new one"
home=$(mktemp -d)/loose
mkdir -p "$home/keys"
chmod 755 "$home" "$home/keys"
ANTARIUM_HOME="$home" "$BIN" --status >/dev/null 2>&1
mode=$(stat -f "%Sp" "$home")
keys=$(stat -f "%Sp" "$home/keys")
[ "$mode" = "drwx------" ] && ok "a loose settings directory is tightened" \
    || bad "settings directory left as $mode by a command-line run"
[ "$keys" = "drwx------" ] && ok "a loose keys directory is tightened" \
    || bad "keys directory left as $keys by a command-line run"
rm -rf "$home"

# Every resource the code asks its bundle for, present in the assembled app.
#
# AppResources prefers Bundle.main so an installed build never depends on the
# build machine. Nothing checked that it can: build.sh copies each resource
# behind an `if [[ -f ]]`, so a rename or a moved file is a silent skip.
#
# Tried it. With Resources/pricing.json moved aside the app builds, launches
# and reports usage exactly as before, exit zero — because Bundle.module
# falls back to the absolute path of .build on this machine, which is the
# dependency the comment in AppResources exists to rule out. On anybody
# else's Mac that path does not exist. A failure that is invisible here and
# total there is the one worth a gate.
step "The assembled app carries every resource it asks for"
missing=0
res=dist/Antarium.app/Contents/Resources
for name in $(grep -rhoE 'forResource: ?"[^"]+", ?withExtension: ?"[^"]+"' Sources/ \
              | sed -E 's/.*forResource: ?"([^"]+)".*withExtension: ?"([^"]+)".*/\1.\2/' | sort -u); do
    # Anywhere under Resources: the same call often names a subdirectory too,
    # and the first version of this check reported the logo missing when it
    # was one folder down.
    find "$res" -name "$name" | grep -q . || { bad "the app has no $name"; missing=1; }
done
for dir in $(grep -rhoE 'subdirectory: ?"[^"]+"' Sources/ \
             | sed -E 's/.*"([^"]+)".*/\1/' | sort -u); do
    [ -d "$res/$dir" ] || { bad "the app has no $dir/"; missing=1; }
done
# Read at runtime for the compatibility rows, through a path this grep cannot
# see: the fixture name comes out of the descriptor.
[ -d "$res/harness-fixtures" ] || { bad "the app has no harness-fixtures/"; missing=1; }
[ $missing -eq 0 ] && ok "every resource the code names is in the app"
# And the fallback really is absent, which is what makes a miss fatal rather
# than quiet.
if find dist/Antarium.app -name "*.bundle" | grep -q .; then
    bad "a SwiftPM resource bundle is inside the app — a missing resource would be hidden"
else
    ok "no SwiftPM bundle to fall back to"
fi

# The remote path, checked without a second machine. Nothing ran this command
# until now — not this script, not the suite — and it had a hole worth
# finding: every property it reports is `allSatisfy`, which holds of no rows
# at all, so a reply that parsed and yielded nothing printed four ticks and
# exited zero.
step "A synthetic remote reply is replayed through the real parser"
reply=$(mktemp)
printf '100\t%%%%1\t/fixture/project\n__ANTARIUM_PS__\n100 1 claude\n__ANTARIUM_EXE__\n100 /fixture/agent/claude\n__ANTARIUM_STATUS__:0:0:0\n__ANTARIUM_DONE__\n' > "$reply"
if out=$("$BIN" --verify-remote-discovery-reply "$reply" 2>&1); then
    printf '%s' "$out" | grep -q '"verified":true' \
        && ok "a complete reply produces rows and passes" \
        || bad "a complete reply passed without verifying anything: $out"
else
    bad "a complete synthetic reply was refused: $out"
fi
# And the empty one is refused, so the tick above means something.
printf '__ANTARIUM_PS__\n__ANTARIUM_EXE__\n__ANTARIUM_STATUS__:0:0:0\n__ANTARIUM_DONE__\n' > "$reply"
if "$BIN" --verify-remote-discovery-reply "$reply" >/dev/null 2>&1; then
    bad "a reply with no rows in it passed"
else
    ok "a reply with nothing in it is not a pass"
fi
rm -f "$reply"

step "A first run leaves its settings directory private"
home=$(mktemp -d)
chmod 755 "$home"
ANTARIUM_HOME="$home" "$APP" >/dev/null 2>&1 & pid=$!
sleep 6; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
mode=$(stat -f "%OLp" "$home")
[ "$((8#$mode & 8#077))" -eq 0 ] && ok "settings directory is 0$mode" \
    || bad "settings directory is 0$mode — another user of this Mac can read it"
if [ -d "$home/keys" ]; then
    kmode=$(stat -f "%OLp" "$home/keys")
    [ "$((8#$kmode & 8#077))" -eq 0 ] && ok "keys directory is 0$kmode" \
        || bad "keys directory is 0$kmode"
else
    bad "no keys directory was created"
fi
rm -rf "$home"

# A settings file, a descriptor or a cache can be truncated by a full disk, a
# crash mid-write, or somebody editing one by hand. None of that should stop
# the app starting, and a corrupt descriptor should cost that one harness
# rather than all of them.
step "A machine whose files have been damaged"
home=$(mktemp -d)
ANTARIUM_HOME="$home" "$BIN" --status >/dev/null 2>&1
before=$(ls "$home"/harnesses/*.json 2>/dev/null | wc -l | tr -d ' ')
printf '{ not json' > "$home/config.json"
printf 'GARBAGE' > "$home/harnesses/cursor.json"
out=$(ANTARIUM_HOME="$home" "$BIN" --status 2>&1); status=$?
[ "$status" -eq 0 ] && ok "it still starts" || bad "a damaged file stopped it starting"
printf '%s' "$out" | grep -q "harnesses $((before - 1)) loaded" \
    && ok "one bad descriptor cost one harness" \
    || bad "a bad descriptor cost more than itself"
printf '%s' "$out" | grep -q "Settings could not be read safely" \
    && ok "the unreadable settings file is reported" \
    || bad "an unreadable settings file was not mentioned"
rm -rf "$home"

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
# What it showed is what it wrote. These used to come from two separate reads
# of the disk — the ● marks from one scan, the recorded choice from another —
# so a machine that changed between them produced a report of a decision
# nobody made.
shown=$(printf '%s' "$out" | sed -n 's/^● \([^ ]*\).*/\1/p' | sort | tr '\n' ',' | sed 's/,$//')
wrote=$(printf '%s' "$out" | sed -n 's/^wrote      enabledAgents = //p' | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
if [ "$shown" = "$wrote" ]; then
    ok "it wrote the choice it explained"
else
    bad "explained [$shown] and wrote [$wrote]"
fi
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

# The benchmark below times one scan. The failure this project was rebuilt
# around was not a slow scan but a frequent one — 408 minutes of CPU over
# fifteen hours, which is 44% of a core sustained, from a loop running far
# more often than it should. No single-scan timing can see that, so this
# measures what the app actually costs while it sits there.
#
# The second half only: the first thirty seconds are cold caches and first-run
# detection, which are legitimately busy and say nothing about steady state.
step "Sustained cost while idle"
if [ -x "$APP" ]; then
    home=$(mktemp -d)
    ANTARIUM_HOME="$home" "$APP" >/dev/null 2>&1 & soak=$!
    sleep 30
    first=$(ps -o time= -p "$soak" 2>/dev/null | tr -d ' ')
    sleep 30
    second=$(ps -o time= -p "$soak" 2>/dev/null | tr -d ' ')
    rss=$(ps -o rss= -p "$soak" 2>/dev/null | tr -d ' ')
    kill "$soak" 2>/dev/null; wait "$soak" 2>/dev/null
    rm -rf "$home"
    if [ -z "$first" ] || [ -z "$second" ]; then
        bad "the app did not stay running for a minute"
    else
        spent=$(python3 -c "
def secs(t):
    m, s = t.split(':') if ':' in t else ('0', t)
    return int(m) * 60 + float(s)
print('%.2f' % (secs('$second') - secs('$first')))")
        mb=$(( ${rss:-0} / 1024 ))
        printf '   %s s of CPU in the second thirty, %s MB resident\n' "$spent" "$mb"
        # Generous: a healthy build spends well under a second here. The
        # ceiling is set to catch the shape of the original failure, not a
        # busy laptop.
        python3 -c "import sys; sys.exit(0 if float('$spent') <= 6 else 1)" \
            && ok "idle cost within budget" \
            || bad "idle cost is $spent s per 30 s — the shape of a runaway loop"
        [ "$mb" -le 400 ] && ok "resident size ${mb} MB" \
            || bad "resident size ${mb} MB"
    fi
else
    bad "no built app at $APP"
fi

step "Scan benchmark"
home=$(mktemp -d); mkdir -p "$home/harnesses"; cp Resources/harnesses/*.json "$home/harnesses/"
ANTARIUM_HOME="$home" "$BIN" --bench >/dev/null 2>&1
# --bench reports the harness count it measured and whether transcripts are
# still being absorbed, so there is nothing to recompute here. It exits
# non-zero when the fastest pass is over budget, which this step used only to
# print — a scan ten times slower was reported underneath "All checks passed".
bench=$(ANTARIUM_HOME="$home" "$BIN" --bench 2>&1); status=$?
printf '%s\n' "$bench" | sed 's/^/   /'
[ "$status" -eq 0 ] && ok "scan within budget" || bad "scan is over its budget"
rm -rf "$home"

printf '\n'
[ $fails -eq 0 ] && { echo "All checks passed."; exit 0; }
echo "$fails check(s) failed."; exit 1
