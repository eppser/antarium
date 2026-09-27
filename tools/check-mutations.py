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
from typing import Optional
import difflib
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

    The delimiter used to be listed — `|`, `/`, `#`, `,` — and dozens of
    entries use `%`, so they were never counted. Thirty-two multi-site entries
    were invisible here, including the one that broke all four of
    `FieldPath`'s boolean guards together and hid two missing tests behind the
    two that objected. Any character sed accepts as a delimiter counts now:
    anything that is not a letter, a digit, whitespace or a backslash.
    """
    return bool(re.match(r'^s([^\sA-Za-z0-9\\])', expression)) and ';' not in expression


#: The fewest entries this catalogue may hold and still be a catalogue. See the
#: check at the end of `main` for why a floor rather than a non-empty test.
MINIMUM_ENTRIES = 1_000


def partial_on_a_line(expression: str, target: str) -> Optional[str]:
    """The literal this substitutes, when it occurs twice on one line and `g` is absent.

    `sed` substitutes once per line, so a pattern on several lines is fully
    replaced without `g` — what is not is a pattern twice on *one* line. A note
    is one long line, and a note states a thing once in a list and again in the
    sentence that acts on it: mutating such an entry removes one mention and
    leaves the other, so the test that should catch it is answered by what
    remains and the entry reads as a missing test.

    Found twice by hand before this looked for it — Z.ai's second brand, named
    three times in one note, and Vercel's gateway host, named twice.
    """
    if expression.rstrip().endswith('g'):
        return None
    # An address may come first — `/"note":/ s|a|b|` and `/x/,/y/ s|a|b|` are
    # both substitutions, and the addressed ones are the case that matters most:
    # a note is the thing addressed, and a note is where a claim gets stated
    # twice. The first version of this looked only for a bare `s` and so passed
    # the two entries it was written for.
    body = re.sub(r'^\s*/(?:\\.|[^/\\])*/(?:\s*,\s*/(?:\\.|[^/\\])*/)?\s*', '', expression)
    if not body.startswith('s') or len(body) < 2:
        return None
    delimiter = body[1]
    parts = re.split(r'(?<!\\)' + re.escape(delimiter), body[2:])
    if len(parts) < 2:
        return None
    pattern, replacement = parts[0], parts[1]
    literal = pattern.replace('\\', '')
    # An insertion keeps its own pattern on purpose.
    if not literal or literal in replacement:
        return None
    try:
        with open(target, encoding='utf-8', errors='replace') as handle:
            for line in handle:
                if line.count(literal) > 1:
                    return literal
    except OSError:
        return None
    return None


def main(path: str) -> int:
    dead = []
    broad = []
    partial = []
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
            if literal := partial_on_a_line(expression, target):
                partial.append((name, literal))
            if plain_substitution(expression):
                b, a = before.splitlines(), result.stdout.splitlines()
                if len(b) == len(a):
                    hits = sum(1 for x, y in zip(b, a) if x != y)
                else:
                    # A substitution that empties a line keeps the count; one
                    # whose replacement carries a newline does not. Counted
                    # either way, or an entry that removes a rule at four
                    # sites reads here as an entry that removes one.
                    hits = sum(i2 - i1 for tag, i1, i2, _, _
                               in difflib.SequenceMatcher(None, b, a).get_opcodes()
                               if tag in ('replace', 'delete'))
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
    # A failure, not advice: an entry that removes one of two mentions on a line
    # leaves the test that should catch it satisfied by the other, which is
    # indistinguishable from a rule nothing defends. Adding `g` is the fix.
    for name, literal in sorted(partial):
        print(f'   FAIL mutation "{name}" leaves a second "{literal}" on the same '
              + 'line — add g to the substitution')
    print(f'   {live} mutations still apply'
          + (f', {len(dead) + len(set(duplicates))} do not' if dead or duplicates else '')
          + (f', {len(partial)} apply only partly' if partial else ''))
    # A catalogue with nothing in it applied perfectly.
    #
    # This reported "0 mutations still apply" and exited zero, so an emptied or
    # truncated `mutations.txt` passed the gate — the same shape as the emptied test
    # file that let the suite run green with seven tests missing. A floor rather than
    # merely "not empty", because a truncation leaves a prefix rather than nothing,
    # and a prefix would sail through a non-empty check.
    #
    # Set well below the current count so removing stale entries stays ordinary.
    # Raise it when it starts feeling generous; that is a better problem than the
    # one it replaces.
    if live + len(dead) < MINIMUM_ENTRIES:
        print(f'   FAIL the catalogue holds {live + len(dead)} entries, fewer than the '
              f'{MINIMUM_ENTRIES} this project expects — emptied or truncated?')
        return 1
    return 1 if dead or duplicates or partial else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'mutations.txt'))
