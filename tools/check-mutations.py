#!/usr/bin/env python3
"""Reports mutations whose pattern no longer matches the source.

A mutation that does not apply is reported by mutate.sh as PATTERN NO LONGER
MATCHES, but only when the catalogue is run in full — which takes hours. This
is the same check in seconds, so a refactor that invalidates an entry is
caught at the next verify rather than at the next full run.

They rot for an ordinary reason: the code the mutation targets gets rewritten
and nobody re-checks the catalogue. Three entries here rotted a different
way — a corrected mutation was appended after a failed attempt, and the
deduplication kept the first.
"""
import os
import re
import subprocess
import sys

def plain_substitution(expression: str) -> bool:
    """True for a bare `s|a|b|` with no address and no second command.

    Such an expression is applied to every line, so a pattern that occurs
    twice is mutated twice. That is sometimes meant — Dashboard.swift carries
    two near-identical `help` builders and a rule broken in one should be
    broken in both — and sometimes it is an entry quietly covering more than
    its name claims.
    """
    return bool(re.match(r'^s([|/#,])', expression)) and ';' not in expression


def main(path: str) -> int:
    dead = []
    broad = []
    seen = {}
    duplicates = []
    live = 0
    for raw in open(path, encoding='utf-8'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|', 2)]
        if len(parts) != 3:
            dead.append((line[:60], 'malformed'))
            continue
        name, target, expression = parts
        if not os.path.exists(target):
            dead.append((name, 'file missing: ' + target))
            continue
        before = open(target, encoding='utf-8').read()
        result = subprocess.run(['sed', expression, target],
                                capture_output=True, text=True)
        if result.returncode != 0:
            dead.append((name, 'sed refused the expression'))
        elif result.stdout == before:
            dead.append((name, 'pattern no longer matches'))
        else:
            live += 1
            # A name is how a catch is reported and how an entry is found
            # again. Two entries sharing one made a corrected mutation look
            # like a duplicate of the thing it replaced, and both stayed —
            # the older one substituting on every matching line, the newer
            # addressed to the single site its name described.
            if name in seen and seen[name] != expression:
                duplicates.append(name)
            seen[name] = expression
            if plain_substitution(expression):
                b, a = before.splitlines(), result.stdout.splitlines()
                if len(b) == len(a):
                    hits = sum(1 for x, y in zip(b, a) if x != y)
                    if hits > 1:
                        broad.append((name, hits))
    for name, why in dead:
        print(f'   FAIL mutation "{name}" {why}')
    for name in sorted(set(duplicates)):
        print(f'   FAIL mutation "{name}" shares its name with a different expression')
    # Advisory, not a failure: matching twice is often correct, and a check
    # that cried wolf on the twenty-odd entries that mean it would be turned
    # off rather than read.
    for name, hits in sorted(broad, key=lambda row: -row[1]):
        print(f'   note  mutation "{name}" substitutes on {hits} lines')
    print(f'   {live} mutations still apply'
          + (f', {len(dead) + len(set(duplicates))} do not' if dead or duplicates else ''))
    return 1 if dead or duplicates else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'mutations.txt'))
