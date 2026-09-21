# Repository instructions

## Purpose and invariants

Antarium is a macOS SwiftPM application and public harness SDK. Preserve these
product contracts:

- Absence, numeric zero, and collection failure are distinct states.
- Never infer or fabricate quota, token, cost, context-window, or session data.
- Agent-specific process, file, folder, SQLite, tab, mapping, and presentation
  facts belong in harness configuration whenever a bounded generic primitive can
  express them.
- Keep stateful OS/service control flow, security boundaries, bounded I/O, cache
  publication, and native authentication in Swift.
- Treat harness files as trusted local configuration. Command sources execute
  argv directly without a shell and all readers must remain bounded.

## Change workflow

- Add or adapt a failing test/evaluation before changing observable behavior.
- Use only synthetic temporary data in tests and fixtures. Never copy local
  transcripts, credentials, usernames, home paths, logs, or account responses.
- When a harness shape changes, update the SDK model, JSON Schema, decoder,
  validation, migration behavior, examples, and contract tests together.
- Prefer additive format-v1 fields. Reject unknown future versions rather than
  guessing their meaning.
- Keep cache fingerprints complete for every input that can change a result.
- Preserve cancellation and scan-generation guards so stale work cannot publish.
- Do not commit generated builds, local agent settings, signing material,
  extracted vendor marks, or compiled helper tools.

## Architecture map

- `Sources/AntariumHarnessSDK`: public typed authoring and migration API.
- `Sources/Antarium/Core`: collection, mapping, caching, lifecycle, and models.
- `Sources/Antarium/Providers`: native authenticated quota integrations.
- `Sources/Antarium/UI`: AppKit/SwiftUI presentation only.
- `Sources/Antarium/Core/RemoteTmux.swift`: SSH-backed tmux discovery on
  other machines. Hosts come from `remoteTmuxHosts`; a password, when one
  is needed, lives in the Keychain. Rows are tagged `tmux-remote` and
  deliberately carry no `tmuxTarget`, which drives the *local* focus path.
- `Resources/harnesses`: shipped declarative descriptors.
- `Resources/harness-fixtures`: synthetic dated compatibility evidence.
- `Tests/AntariumTests`: behavior, architecture, numeric, performance, and UI
  contracts.

## Required verification

Run from the repository root:

```bash
./verify.sh
```

That runs the three commands below and the checks that were otherwise
reassembled by hand: the suite three times — as-is, with no `~/.antarium`, and
outside UTC — every shipped harness through `--check`, the command line on a
machine that has never run it, a first run through the real app path, and the
scan benchmark.

The repeat runs are not redundant. A test that reads the developer's seeded
harnesses passes here and fails on a fresh checkout, which is how eleven of
them sat red in CI while green locally. And CI runners are UTC, where a date
bug that reads timestamps in the local zone cannot show at all: interpreting
ISO timestamps locally passes every test under `TZ=UTC` and fails two thousand
under a half-hour offset. Kolkata is chosen for that half hour — a whole-hour
zone misses an error that is itself a multiple of an hour. Every step that writes runs under `ANTARIUM_HOME` in a
temporary directory, so none of it touches your own settings. It also reports
when the benchmark is still absorbing transcript history, because those numbers
are throughput rather than steady state.

When changing a test, or when a change makes one stop failing:

```bash
./mutate.sh
```

It breaks the application on purpose, one rule at a time, and reports anything
the tests do not notice. Every mutation in `mutations.txt` has been confirmed
to fail at least one test, so a `SURVIVED` line means a test was weakened or
deleted — the one failure mode nothing else here can see, because a suite of
tests that cannot fail looks exactly like a suite that passes. A mutation that
no longer applies is also reported: the rule it guarded may have been rewritten
without anyone noticing.

Every mutation is reverted, including on interrupt. It takes several minutes,
so it is not part of `verify.sh`.

The commonest way to write a test that cannot fail is to derive what you
expect from the thing you are testing. A test reading
`chain(RemoteTmux.maxPaneDepth - 1)` passes for every value of
`maxPaneDepth`, so lowering the bound is a change nothing objects to. Write
the number out, and assert the constant separately — then the two tests
disagree when somebody moves it. The same applies to a `count` compared
against `Registry.all.count`, and to any expectation built by calling the
function under test. Observe the value first, then assert it.

A mutation that removes a sort is caught only if the unsorted order differs
from the sorted one, and with a small fixture it often does not: three rows
come out of a `Dictionary` in ascending order about one run in six, and the
seed changes per process, so the same mutation is caught on one run and
survives the next. Ordering fixtures want eight or ten entries, written out
of order. A `SURVIVED` line that does not reproduce is this, not luck.

A mutation reported as `caught (never finished)` was caught by a test that
hung rather than one that failed. That is a real catch and the harness treats
it as one, but it is a slow one: prefer a test that fails outright on the same
mutation, and keep the hanging case only when the shape it covers — a cycle,
an unbounded stream — is the reason the bound exists.

The parts, if you need one on its own:

```bash
./test.sh
swift build --scratch-path /tmp/antarium-strict \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
./build.sh
```

For harness changes, also run the built executable with
`--verify-harness-fixtures`, `--verify-harness-installations`, and `--check`
against the changed descriptor when the corresponding upstream application is
installed. For remote tmux changes, `--remote-tmux [host ...]` reports what each
configured machine answered, including why one contributed nothing. A process-backed bundled harness must carry positive installation
probes and negative collision/helper probes with synthetic paths and dated
official evidence.

## Code review rules

- Flag any path that converts an error or unknown state into zero, empty, idle,
  or healthy output.
- Flag agent-specific Swift parsing that a generic descriptor primitive can
  represent safely.
- Flag credentials, prompts, raw argv, transcript text, usernames, absolute home
  paths, or real account responses in source, logs, tests, fixtures, or snapshots.
- Flag unbounded file reads, subprocess output, SQL results, glob expansion,
  network waits, or caches.
- Flag a published numeric claim unless a reproducible command or exact fixture
  contract supports it.
