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

A positive `contains` over a whole file or a command's whole output proves
only that the string exists somewhere in it, which is rarely the claim. Three
times this month one passed for the wrong reason: a host check satisfied by
`evilx.ai`, a key path matched by a longer path sharing its prefix, and a
documentation step still "present" because the same command appeared in
another section. Scope the haystack to the region meant, or match something
that cannot occur elsewhere — a count, a whole line, a delimited token. A
*negative* `contains` over a whole file is the opposite: absence everywhere
is usually exactly the claim, and the wide haystack is the point.

A test that asserts inside a loop asserts nothing when the loop does not run,
and a parameterised test over an empty list passes. Where the collection
comes from the bundle, from the filesystem, or from a list somebody maintains
by hand, count what was examined and assert the count — `verify.sh` already
refuses a test run that reports no tests, and this is the same rule one level
in.

A rule that lists its subjects covers only the instances that prompted it.
The test that stopped four surfaces claiming an agent was "not installed"
named those four files, and two providers went on making the same claim from
a failed PATH lookup — in the two places most exposed to it. A source rule
should enumerate `Sources` recursively, and assert a file count above what
the narrower scope would have contained, so that narrowing it back fails
rather than passing either way.

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

Two guards that each suffice cannot be caught one at a time. `cancel()` in
`RemoteScanController` both bumps the generation and cancels the task, and a
completion has to pass both checks — so deleting either alone changes nothing
observable and is not a gap. Where that shape appears, hold one entry that
removes the pair, and say in the source why the redundancy is there. The
alternative is two entries nothing can catch, which reads as missing coverage
for a thing that is covered twice.

A test declared `@Test func name()` with no display name reports its failure
as `✘ Test name()`, unquoted. The runner used to look for `✘ Test "`, so
every mutation whose only cover was such a test was announced as SURVIVED —
fifteen of them here, covering the state machine and the loop watch. Prefer a
display name; the runner no longer depends on it either way.

A full run prints the commit it started from, and that line is the first
thing to read in an old report. The run takes hours in a detached checkout
made when it began, so a report read afterwards describes a tree that no
longer exists: entries added since show as "could not be applied", and
entries a later test now catches still show as SURVIVED. Re-run the survivors
against the current tree before believing any of them — `grep SURVIVED` the
log, match the names back to `mutations.txt`, and run that subset.

`caught (the tests no longer build)` means the sources still compile and the
tests do not — which is how removing a field the SDK publishes is caught: the
round-trip that writes it stops compiling. A real catch, and a different
event from a trap.

`caught (the suite did not survive it)` means the mutation made the tests
trap rather than fail — an index that went negative, a force-unwrap that
stopped holding. That is a catch, and a loud one. The runner used to look
only for a reported `✘ Test` line, so a trap printed a fatal error, produced
no such line, and was announced as SURVIVED: the answer it must never give,
given for the loudest failure there is. If you are reading an old report, a
survivor that looks impossible may have been this.

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

`verify.sh` measures two different costs and they are not substitutes. The
scan benchmark times one pass; the idle step runs the built app for a minute
and measures what it spends in the second half of that. The failure this
project was rebuilt around was a frequent scan rather than a slow one — 44%
of a core sustained — and no single-pass timing can see it. A healthy build
spends well under a second in that window and sits at about 80 MB.

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
- Flag a check that derives its subjects from the thing it checks, without
  counting them. A test reading resource names out of the sources, or a
  verify.sh step reading them with grep, loses its subjects when the call is
  renamed and then reports that every one of nothing was fine. Count what was
  examined and refuse a count that is too low — three instances of this were
  found in one afternoon, in Swift and in shell.
- Flag a check that loops over the very list it is pinning. Asserting that
  each entry of `CommandPath.fallbacks` is searched says nothing about an
  empty `fallbacks`, and emptying it is the change that matters: an app
  launched from Finder inherits a minimal PATH and has only that list to find
  an installed agent with. Name the entries the check requires, then assert
  the declared list is a subset — the loop pins the contents, the literal
  pins that there are any.
- Flag vendor text drawn in a surface of fixed size. Bounding a reader keeps
  a response from costing unbounded work; it does not keep the response from
  costing unbounded *space*. Four of these were found in one week: a cloud
  task's status wrapping its row, a plan label pushing a row past its panel,
  a state pill with no line limit, and a balance whose currency made one menu
  bar item 540 points wide — 1,993 with the figure beside it. The reader's
  limit is the wrong limit for a row and badly wrong for the menu bar, which
  is shared with every other application on the machine. Ask what the widest
  thing the field can hold measures where it is drawn, and hold the cell to
  one line so an overflow truncates rather than wrapping — `fixedSize`
  prevents a shrink, not a wrap.
- Flag a set of tests that only ever compare one result against another. A
  budget was asserted to be smaller when a child was added, larger than a
  third of the panel, and different from its neighbour — all true of a
  formula wrong by the same amount everywhere, and two mutations lived
  through it. A difference test says the shape is right; something has to
  say the number is. Pin one absolute figure against a fact established
  outside the code under test — counted from the view, measured from the
  font — and let the differences cover the rest.
- Flag a test that names a branch its inputs cannot reach. "With no day
  stated, the sentence is unchanged" called a function that reads the bundled
  pricing table, and that table always states a day, so it checked the dated
  sentence for a defect only the undated one can have; deleting the guard
  left it green, and its own comment said the branch was "not reachable
  here". When a comment concedes that, the fix is a parameter, not a
  narrower assertion — and then assert both sides, or "return it unchanged"
  can be the whole implementation.
- Flag logic keyed on a string the user reads. The dashboard's "N still
  reading" counted rows whose note contained "still being read", a sentence
  written in two other files; the remote verifier asked whether a state's
  label was "Unknown", which a cloud state whose own text is "unknown"
  matches. Both should share a cause with what they describe — a flag on the
  row, a case on the enum — not a phrase.
- Flag a source rule whose forbidden spellings are not the ones this project
  writes with. A list assembled from memory forbids nothing: the first draft
  of the read-only credential rule matched neither the settings store, which
  writes through `open`/`Darwin.write`/`rename`, nor the seeder, which goes
  through `PrivateFile.write`. Ask the rule of a file that certainly does the
  thing, in the same test.
- Flag a concurrency test that contends a warm cache. A memoising cache read
  from several threads races nothing once it is populated, so such a test
  passes with the lock removed and proves only that reading is safe. Contend
  the path that writes: a key nothing has asked about yet, or a rebuild
  forced on every thread. Three of these were written the weak way before the
  mutation showed it, and the registry's own lock was the one that mattered —
  a lost race there is a second URLSession per harness, for ever.
- Flag `Int(someDouble)` where the double came off a network, out of a file
  another application writes, or from arithmetic on either. The conversion
  traps outside `Int`'s range and on NaN — it does not round and it does not
  throw, the process dies — and `1e30` is legal JSON. Three provider mappings
  converted a response number that way. `FieldPath.epoch` bounds a date and
  `FieldPath.seconds` bounds a window; `Int(exactly:)` is the answer where a
  count is genuinely wanted.
- Flag a test whose expected value is also what the code produces when the rule
  under test does nothing. A first-run test asserting that the used agent is
  enabled named that same agent first in the provider list, where the
  no-evidence fallback would have put it anyway: it passed whether detection
  worked or not, and the mutation that discarded the whole session set
  survived it. Choose inputs where the right answer and the fallback differ.
