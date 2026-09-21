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
import subprocess
import sys

def main(path: str) -> int:
    dead = []
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
    for name, why in dead:
        print(f'   FAIL mutation "{name}" {why}')
    print(f'   {live} mutations still apply'
          + (f', {len(dead)} do not' if dead else ''))
    return 1 if dead else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'mutations.txt'))
