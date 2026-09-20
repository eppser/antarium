#!/bin/bash
# Breaks the app on purpose, one rule at a time, and reports anything the
# tests do not notice.
#
# This is not a bug hunt. Every mutation in mutations.txt has been confirmed to
# fail at least one test, so a SURVIVED line means a test was weakened or
# deleted. That is the failure mode nothing else here can see: a suite of tests
# that cannot fail looks exactly like a suite that passes.
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
        swift build >"$BACKUP/build" 2>&1
        if grep -q 'error:' "$BACKUP/build"; then
            printf '  %-46s does not compile\n' "$name"
            broken=$((broken+1))
        elif ./test.sh >"$BACKUP/out" 2>&1; grep -q '^✘ Test "' "$BACKUP/out"; then
            printf '  %-46s caught\n' "$name"
            caught=$((caught+1))
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
