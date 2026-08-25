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
- `Resources/harnesses`: shipped declarative descriptors.
- `Resources/harness-fixtures`: synthetic dated compatibility evidence.
- `Tests/AntariumTests`: behavior, architecture, numeric, performance, and UI
  contracts.

## Required verification

Run from the repository root:

```bash
./test.sh
swift build --scratch-path /tmp/antarium-strict \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
./build.sh
```

For harness changes, also run the built executable with
`--verify-harness-fixtures` and `--check` against the changed descriptor when
the corresponding upstream application is installed.

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
