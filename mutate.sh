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
