# Claude Code repository guidance

Read and follow [AGENTS.md](AGENTS.md); it is the canonical repository guide.

Before implementation, add or adapt a test/evaluation that demonstrates the
desired behavior. Preserve the distinction between missing, zero, unknown, and
failed data. Never create plausible-looking quota, token, cost, context-window,
or session numbers when evidence is absent.

Prefer harness configuration for agent-specific process, file, folder, JSONL,
SQLite, command, UI-tab, mapping, capability, lifecycle, and presentation facts.
Keep bounded I/O, concurrency, cache publication, OS integration, and native
authentication in Swift. Descriptor changes must remain aligned across the SDK,
schema, decoder, migration, documentation, fixtures, and tests.

Use only synthetic fixtures and temporary directories. Do not read or commit
local transcripts, credentials, account responses, logs, usernames, home paths,
agent settings, extracted vendor artwork, signing files, or generated builds.

Run `./test.sh`, the strict-concurrency build documented in `AGENTS.md`, and
`./build.sh` before declaring a code change complete.
