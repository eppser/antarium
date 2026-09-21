#!/usr/bin/env python3
"""Prints a Swift file with string literals and comments blanked out.

mutate.sh uses this to tell a real mutation from one that only edited a
message. A mutation whose blanked form is unchanged cannot alter behaviour, so
its survival says nothing about the tests — and reads exactly like a missing
test, which is how it cost four separate afternoons before this existed.
"""
import sys


def strip(src: str) -> str:
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            out.append('""')
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith('/*', i):
                    depth += 1
                    i += 2
                elif src.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


if __name__ == '__main__':
    sys.stdout.write(strip(open(sys.argv[1], encoding='utf-8').read()))
