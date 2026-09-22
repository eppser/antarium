#!/bin/bash
# Breaks the app on purpose, one rule at a time, and reports anything the
# tests do not notice.
#
# This is not a bug hunt. Every mutation in mutations.txt has been confirmed to
# fail at least one test, so a SURVIVED line means a test was weakened or
# deleted. That is the failure mode nothing else here can see: a suite of tests
# that cannot fail looks exactly like a suite that passes.
#
# Writing one: mutate the expression that ENFORCES a rule, not the constant it
# compares against, and not the message it produces. A survivor whose change
# touched only a string or a comment is annotated as such, because four
# separate afternoons went on mutations that could not have behaved
# differently and read exactly like missing tests. A constant wrapped in `min(…)`, `max(…)` or `??` is
# frequently overridden a line later, so changing it alters no behaviour, the
# tests pass, and the report says SURVIVED — which reads exactly like a
# missing test. Three exploratory mutations went that way in one afternoon.
# A survivor means the mutation and the tests disagree about what matters;
# check which of the two is wrong before believing either.
#
# The catalogue itself cannot be corrupted this way: a no-op survives, and only
# mutations confirmed caught are recorded.
#
# Every mutation is reverted, including on interrupt.
set -uo pipefail
cd "$(dirname "$0")"

CATALOGUE=${1:-mutations.txt}

# Run in a throwaway checkout, not in the tree you are working in.
#
# Every mutation rewrites a source file and restores it afterwards, so a full
# catalogue run holds the working tree hostage for as long as it takes — and
# it takes a while: a build and a full suite per entry. Editing anything
# meanwhile corrupts both the edit and the run. Worse, an interrupted run can
# leave a mutated file behind, which looks like a bug you just introduced.
#
# A git worktree costs one checkout and removes the whole problem. --no-isolate
# keeps the old behaviour for a quick single-mutation check, where the copy
# costs more than it saves.
ISOLATE=yes
[ "${1:-}" = "--no-isolate" ] && { ISOLATE=no; shift; CATALOGUE=${1:-mutations.txt}; }

if [ "$ISOLATE" = yes ] && [ -z "${MUTATE_IN_WORKTREE:-}" ]; then
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "not a git repository — running in place"
    else
        CAT_ABS=$(cd "$(dirname "$CATALOGUE")" && pwd)/$(basename "$CATALOGUE")
        TREE=$(mktemp -d)/mutate
        echo "running in a throwaway checkout so this tree stays usable"
        git worktree add --detach --quiet "$TREE" HEAD || exit 1
        # Uncommitted work is what you are usually testing, so carry it over.
        git diff HEAD | (cd "$TREE" && git apply --allow-empty -) || {
            echo "could not carry uncommitted changes into the checkout"
            git worktree remove --force "$TREE"; exit 1
        }
        # `git diff` says nothing about files git has never seen, and a new
        # test file is exactly that. Without this the checkout builds and
        # passes without the tests you just wrote, so every mutation survives
        # and the report blames your code instead of this script. That is how
        # the first run of this went.
        untracked=$(git ls-files --others --exclude-standard)
        if [ -n "$untracked" ]; then
            printf '%s\n' "$untracked" | while IFS= read -r f; do
                mkdir -p "$TREE/$(dirname "$f")"
                cp "$f" "$TREE/$f"
            done
        fi
        trap 'git worktree remove --force "$TREE" >/dev/null 2>&1' EXIT
        MUTATE_IN_WORKTREE=1 "$TREE/mutate.sh" --no-isolate "$CAT_ABS"
        exit $?
    fi
fi

BACKUP=$(mktemp -d)
CURRENT=""

restore() {
    if [ -n "$CURRENT" ] && [ -f "$BACKUP/current" ]; then
        cp "$BACKUP/current" "$CURRENT"
        touch Package.swift
    fi
    rm -rf "$BACKUP"
}
trap 'echo; echo "interrupted — restoring"; restore; exit 130' INT TERM
trap 'restore' EXIT

survived=0 caught=0 broken=0

# Which tree this is about. A full run takes hours, and a report read after
# the working tree has moved on says nothing about the working tree — every
# entry added since is "could not be applied", and every entry a later test
# now catches still reads SURVIVED. Both happened to a run this week, and the
# report gave no way to tell.
printf 'against %s (%s)\n' "$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
    "$(git log -1 --format=%s 2>/dev/null | cut -c1-60 || echo '')"


# A mutation can remove a loop bound, and then the suite never finishes. macOS
# ships no `timeout`, so the run is backgrounded and killed. A hang is a caught
# mutation: not finishing is a way of failing, and the alternative is a runner
# that stops at the first one.
run_tests() {
    local log=$1 pid limit=${MUTATE_TIMEOUT:-600} waited=0
    ./test.sh >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$limit" ]; then
            # The children matter more than the shell. `swift test` is a child
            # of test.sh, and killing only the parent leaves it running — still
            # holding the log open, still writing at its inherited offset, over
            # anything appended after. The first version of this reported such a
            # mutation as SURVIVED, which is the one answer it must never give.
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# The suite has to pass before anything is mutated.
#
# Every verdict here is "the suite failed, therefore the mutation was
# caught". If it was already failing, every mutation is reported as caught
# and the report is worthless in the direction that matters — it says the
# catalogue is covered when it is not. That happened: a test read a file that
# is in .gitignore, so it passed in the tree it was written in and failed in
# the throwaway checkout this runs in, and fourteen entries went into the
# catalogue on the strength of it. Thirteen were real. One was not.
#
# This costs one build and one suite per invocation, which is the price of
# the results meaning anything.
printf 'checking the suite passes before mutating anything\n'
if ! run_tests "$BACKUP/baseline"; then
    echo
    echo "the suite is already failing, so every mutation would report as caught:"
    grep -E '^✘ ' "$BACKUP/baseline" | head -5 | sed 's/^/   /'
    echo "   (full output in $BACKUP/baseline)"
    echo
    echo "nothing was mutated."
    exit 2
fi

while IFS='|' read -r name file expression; do
    name=$(echo "$name" | sed 's/^ *//;s/ *$//')
    file=$(echo "$file" | sed 's/^ *//;s/ *$//')
    expression=$(echo "$expression" | sed 's/^ *//;s/ *$//')
    case "$name" in ''|'#'*) continue ;; esac
    [ -f "$file" ] || { printf '  %-46s MISSING FILE %s\n' "$name" "$file"; broken=$((broken+1)); continue; }

    CURRENT="$file"
    cp "$file" "$BACKUP/current"
    sed -i '' "$expression" "$file"
    if cmp -s "$file" "$BACKUP/current"; then
        printf '  %-46s PATTERN NO LONGER MATCHES\n' "$name"
        broken=$((broken+1))
    else
        # A descriptor change reaches the build only when resources are
        # re-copied, which needs the manifest to look newer than them.
        touch Package.swift
        # The build's own exit status, not a word in its output. Grepping for
        # `error:` reported a mutation as "does not compile" — and counted it
        # as inapplicable rather than caught — when `swift build` had exited
        # zero and the mutation was in fact caught by ten failing tests. Any
        # line carrying that substring for any reason took a real catch out of
        # the tally, and would as easily have taken out a survivor. This is
        # the third misreport in this file to come from matching text where a
        # status was available; the two above it are the same lesson.
        if ! swift build >"$BACKUP/build" 2>&1; then
            printf '  %-46s does not compile\n' "$name"
            broken=$((broken+1))
        elif run_tests "$BACKUP/out"; status=$?
              [ "$status" -ne 0 ] || grep -q '^✘ ' "$BACKUP/out"; then
            # Any nonzero exit is a catch, not only a reported failure, and
            # the failure line is matched on `✘ ` rather than on `✘ Test "`.
            # Two things were invisible to the narrower pattern. A mutation
            # can make the suite trap, and a trap prints a fatal error and no
            # report at all. And a test declared `@Test func name()` with no
            # display name prints `✘ Test name()` — unquoted — so every
            # mutation whose only cover was one of those was announced as
            # SURVIVED. There are fifteen such tests here, and they cover the
            # state machine and the loop watch.
            if [ "$status" -eq 124 ]; then
                printf '  %-46s caught (never finished)\n' "$name"
            elif grep -q '^✘ ' "$BACKUP/out"; then
                printf '  %-46s caught\n' "$name"
            elif grep -qE 'Fatal error|Swift runtime failure|Trace/BPT trap|Illegal instruction|exited with unexpected signal' "$BACKUP/out"; then
                # Checked before the `error:` test below, because a trap
                # prints "Fatal error:" — which contains "error:" — and so
                # was reported as the tests failing to compile. Both are
                # catches, so the verdict was right and the reason was wrong,
                # which is the kind of report that sends somebody looking for
                # a build problem that is not there. Two mutations bounding
                # network numbers were announced that way in one afternoon.
                #
                # "exited with unexpected signal" is the same event wearing a
                # different coat: when the test process aborts rather than
                # trapping in Swift, SwiftPM reports the signal and prints no
                # Swift message at all. Removing a lock from a cache does
                # exactly that — sixty-four threads into one dictionary is a
                # SIGABRT, not a `Fatal error:` line.
                printf '  %-46s caught (the suite did not survive it)\n' "$name"
            elif grep -q 'error:' "$BACKUP/out"; then
                # The sources still build — that is checked above — so an
                # error here is the tests failing to. Removing a field the
                # SDK publishes is caught that way: the round-trip that
                # writes it stops compiling. A real catch, and not the same
                # event as a trap.
                printf '  %-46s caught (the tests no longer build)\n' "$name"
            else
                printf '  %-46s caught (the suite did not survive it)\n' "$name"
            fi
            caught=$((caught+1))
        elif [ -x tools/strip-inert.py ] \
             && python3 tools/strip-inert.py "$file" >"$BACKUP/now" 2>/dev/null \
             && python3 tools/strip-inert.py "$BACKUP/current" >"$BACKUP/was" 2>/dev/null \
             && cmp -s "$BACKUP/now" "$BACKUP/was"; then
            # Still a survivor — it is never hidden. But the change was
            # confined to a message or a comment, which usually means the
            # mutation is inert rather than the tests are missing. Usually,
            # not always: a mutation that puts private output into a
            # diagnostic changes only a string and matters a great deal, so
            # this annotates rather than reclassifies.
            printf '  %-46s SURVIVED (message-only change — is the mutation inert?)\n' "$name"
            survived=$((survived+1))
        else
            printf '  %-46s SURVIVED\n' "$name"
            survived=$((survived+1))
        fi
    fi
    cp "$BACKUP/current" "$file"
    CURRENT=""
done < "$CATALOGUE"

touch Package.swift
swift build >/dev/null 2>&1
printf '\n%d caught, %d survived, %d could not be applied\n' "$caught" "$survived" "$broken"
# A mutation that no longer applies is also a failure: the rule it guarded may
# have been rewritten or removed, and nobody would know.
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
