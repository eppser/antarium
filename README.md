# Antarium

[![CI](https://github.com/eppser/antarium/actions/workflows/ci.yml/badge.svg)](https://github.com/eppser/antarium/actions/workflows/ci.yml)
[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE)

Antarium is a macOS menu-bar monitor for coding-agent quota and local/cloud
sessions. It keeps account limits separate from session telemetry: a quota bar
comes from a provider response, while dashboard rows come from process and
on-disk evidence.

The central design rule is that absence, zero, and failure are different
states. A failed command, malformed cloud response, or invalid SQLite query is
reported as an error; it is never converted into a healthy empty result.

## What is configuration-owned

Each agent has one JSON harness. The runtime supplies a small set of safe
collection mechanisms; the harness supplies agent-specific facts.

| Concern | Harness configuration |
|---|---|
| Process recognition | `process.pathContains`, exact `names`, `argv0Contains`, and optional source-file binding |
| Session source | JSON, JSONL, SQLite, command, or none |
| Files and folders | `path`, `glob`, `limit`, `paths`, `pathFields`, `manifest` |
| Record meaning | `map` fields, filters, status values, token semantics |
| Open tabs | `selection` from JSON files, read-only SQLite, or a JSON command |
| Project context | per-agent `capabilities` probes and paths |
| Usage integration | `quota` credential, endpoint, headers, and window mapping |
| Presentation/lifecycle | `presentation`, detached/multi-session, idle/stale thresholds |

This includes Cursor's folder-derived project/session identity and OpenCode's
open-tab state; neither has an agent-specific Swift reader.

Swift remains responsible for behavior that is genuinely control flow:

- bounded file/SQLite/process/HTTP collection and parsing;
- complete cache fingerprints and scan-generation publication;
- process-tree, tmux, AppKit, Keychain, and OAuth behavior;
- Claude Code's live per-PID session registry, which combines published state
  with transcript data and cannot be represented as one static record source;
- built-in Claude and Codex authentication providers.

That boundary keeps harnesses editable without turning JSON into a programming
language.

## Install and test

```bash
./test.sh                       # behavioral, architecture, evaluation and UI tests
./build.sh                      # signed app at dist/Antarium.app
./build.sh --archive            # app, versioned zip, and SHA-256
./build.sh --install            # copy to /Applications and launch
```

`test.sh` finds the Swift Testing framework supplied by Xcode. The release
script uses a clean, dedicated scratch directory so moving the repository does
not leave an invalid absolute module-cache path behind.

For a Swift concurrency audit:

```bash
swift build --scratch-path /tmp/antarium-strict \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
```

## App configuration

Settings are atomically stored in:

```text
~/.antarium/config.json
```

Common values include:

```json
{
  "enabledAgents": ["claude-code", "codex"],
  "refreshMinutes": 10,
  "agentScanSeconds": 10,
  "includeCloudAgents": true,
  "meterMode": "used",
  "agentSort": "status",
  "dashboardPinned": false,
  "beams": 5,
  "rowColors": ["#E77DF9", "#389FF9"]
}
```

`refreshMinutes` controls account-usage polling. `agentScanSeconds` controls
local session scans. They are deliberately independent.

## Harness files

At first launch, shipped descriptors are seeded into:

```text
~/.antarium/harnesses/*.json
```

Untouched shipped files receive updates. Once edited, a file is user-owned and
is preserved. Delete an edited shipped file to restore the bundled version at
the next launch.

A basic JSONL harness:

```json
{
  "$schema": "../harness.schema.json",
  "formatVersion": 1,
  "id": "my-agent",
  "name": "My Agent",
  "process": {
    "pathContains": ["/bin/my-agent"],
    "names": ["my-agent"],
    "argv0Contains": ["my-agent-cli"]
  },
  "source": {
    "kind": "jsonl",
    "path": "~/.my-agent/sessions",
    "glob": "*/*.jsonl",
    "limit": 20
  },
  "map": {
    "sessionID": "id",
    "cwd": "cwd",
    "model": "model",
    "timestamp": "timestamp",
    "inputTokens": "usage.input",
    "outputTokens": "usage.output",
    "cacheRead": "usage.cacheRead",
    "cacheWrite": "usage.cacheWrite",
    "turnWhere": { "type": "assistant" },
    "status": {
      "field": "status",
      "working": ["busy"],
      "idle": ["idle"]
    }
  }
}
```

Field paths are dot-separated. Missing fields remain missing; numeric mappings
are never populated with guesses.

### Source types

- `jsonl` incrementally folds complete appended records. A partial final line
  is retained for the next pass.
- `json` reads one object per matched file.
- `sqlite` runs a read-only query. `columns` declares the semantic meaning of
  each selected column.
- `command` executes an argv array without a shell, drains stdout and stderr
  concurrently with bounded memory, has a hard timeout, and accepts only exit
  code zero plus valid JSON.
- `none` contributes no local sessions; it is useful for a quota-only harness
  or a native live-registry adapter.

Every source fingerprint contains the complete descriptor, matched filenames,
file size/mtime/inode facts, manifests, and SQLite `-wal`/`-shm` sidecars.
Editing a mapping, changing a manifest, deleting an older file, or committing a
WAL write therefore invalidates the right cache.

When several agent processes can work in the same directory, declare
`process.sessionBinding: "openSourceFile"`. Antarium then binds each process to
the matching JSON/JSONL source file it actually holds open. Processes with the
same working directory remain distinct, and helpers without a session file do
not become rows.

### Folder-derived metadata

If metadata is encoded in directory names, declare it instead of adding a
reader. Zero names the file, one its parent, and so on:

```json
"source": {
  "kind": "jsonl",
  "path": "~/.cursor/projects",
  "glob": "*/agent-transcripts/*/*.jsonl",
  "limit": 1,
  "pathFields": {
    "title": { "ancestor": 3, "value": "name" },
    "sessionID": { "ancestor": 1, "value": "name" }
  }
}
```

`value` is `name`, `stem`, or the absolute `path`.

### Manifests and filters

When a sibling file owns missing metadata:

```json
"manifest": {
  "file": "../../state.json",
  "map": { "cwd": "cwd", "title": "title" }
}
```

`source.filter` accepts a session only when records match all configured fields.
This separates products that share one transcript directory, such as Codex CLI
and Codex Desktop.

### SQLite

```json
"source": {
  "kind": "sqlite",
  "path": "~/.local/share/agent/agent.db",
  "query": "SELECT id, directory, title, updated FROM session ORDER BY updated DESC LIMIT 40",
  "columns": ["sessionID", "cwd", "title", "lastActivity"]
}
```

Supported semantic columns are checked by `--check`; unknown columns are not
silently counted as data.

### Open-session selection

A multi-session database often retains closed history. Independent UI state can
select the sessions that are actually open:

```json
"multiSession": true,
"selection": {
  "kind": "jsonFiles",
  "path": "~/Library/Application Support/my.agent",
  "glob": "window.*.dat",
  "records": "tabs",
  "encodedJSON": true,
  "id": "sessionId",
  "filter": { "type": ["session"] }
}
```

Unreadable state is `unknown` and falls back to recent sessions. A successfully
read empty set means no tabs and produces no rows.

The same selection boundary supports a read-only SQLite query:

```json
"selection": {
  "kind": "sqlite",
  "path": "~/Library/Application Support/my.agent/ui.sqlite",
  "query": "SELECT session_id FROM tabs WHERE open = 1",
  "column": "session_id"
}
```

Or an executable that returns a JSON array. It is launched directly without a
shell and must exit successfully:

```json
"selection": {
  "kind": "command",
  "command": "/usr/local/bin/my-agent",
  "args": ["tabs", "--json"],
  "id": "sessionId",
  "filter": { "open": ["true"] }
}
```

### Capabilities

Capabilities are per harness, never borrowed from another agent. Rules support
`content`, `directory`, `jsonObject`, and `toml` probes with project and
inherited paths:

```json
"capabilities": {
  "instruction": {
    "probe": "content",
    "project": ["AGENTS.override.md", "AGENTS.md"],
    "inherited": ["~/.codex/AGENTS.override.md", "~/.codex/AGENTS.md"]
  },
  "skills": {
    "probe": "directory",
    "project": [".agents/skills"],
    "inherited": ["~/.agents/skills"]
  },
  "mcp": {
    "probe": "toml",
    "project": [".codex/config.toml"],
    "inherited": ["~/.codex/config.toml"],
    "keys": ["mcp_servers"]
  }
}
```

The shipped Claude and Codex descriptors contain their current conventions.

### Quota providers

For agents without a built-in authentication flow, `quota` can describe a
read-only JSON endpoint. Credentials can come from an environment variable,
text file, JSON field, or bounded command. Window mappings support used or
remaining percentages, count/limit ratios, reset times, labels, and filters.

Set `verified` only after comparing the mapping with the real service. The UI
marks other integrations unverified. Descriptor quota providers never replace
the built-in Claude or Codex auth paths.

## SDK and schema

`AntariumHarnessSDK` is a public SwiftPM library product with typed models,
validation, sorted encoding, and atomic writes:

```swift
import AntariumHarnessSDK

var source = HarnessConfig.Source(
    kind: .jsonl,
    path: "~/.my-agent/sessions",
    glob: "*.jsonl")
source.limit = 20

var harness = HarnessConfig(
    id: "my-agent",
    name: "My Agent",
    process: .init(pathContains: ["/bin/my-agent"], names: ["my-agent"]),
    source: source,
    map: .init(cwd: "cwd", model: "model", sessionID: "id"))
harness.capabilities = [
    "skills": .init(probe: .directory, project: [".agent/skills"])
]

try harness.write(to: URL(fileURLWithPath: "/tmp/my-agent.json"))
```

Every current document carries `formatVersion: 1`. Unversioned v0 documents
are migrated in memory and retain their meaning; a future version is rejected
instead of being guessed. Authors can produce canonical current bytes without
depending on the app target:

```swift
let result = try HarnessConfigMigration.migrate(oldData)
try result.data.write(to: destination, options: .atomic)
```

The app also offers an explicit, non-destructive file-to-file migration:

```bash
$BIN --migrate-harness old.json migrated.json
```

The canonical JSON Schema is [Resources/harness.schema.json](Resources/harness.schema.json).
The runtime checker additionally evaluates mappings against real source records:

```bash
dist/Antarium.app/Contents/MacOS/Antarium \
  --check ~/.antarium/harnesses/my-agent.json
```

It catches unknown nested keys, invalid source kinds/columns, paths that match
nothing, and numeric fields that resolve to objects or strings.

Bundled generic readers additionally have dated fixtures under
`Resources/harness-fixtures`. The fixtures execute real globs, manifests,
journal folding, filters, mappings, and SQLite queries and compare every
reported session number exactly:

```bash
$BIN --verify-harness-fixtures
$BIN --evaluate-harness my-agent.json   # exact JSON work/session metrics
```

`fixture verified` means precisely that those committed bytes pass. It does
not claim an upstream private format can never change. `--check` is the live
validation against data installed on the current Mac.

## Numeric integrity

- Token facts are cached; estimated cost is recomputed with the current price
  table, so a price correction does not require reparsing transcripts.
- `Resources/pricing.json` is dated `2026-08-25` and links its official source.
  Input, output, five-minute and one-hour cache-write, cache-read, and
  context-window values are explicit configuration fields.
- The dashboard labels API-equivalent cost as an estimate. Subscription usage
  is not represented as a bill.
- Cache reads are not labelled as uploaded bytes. Stable logical session IDs do
  not depend on process replacement when session evidence exists.
- Run-wrapper metadata stores argument count, never raw prompts or tokens.

Override or extend prices with the same explicit shape at:

```text
~/.antarium/pricing.json
```

Entries missing cache rates are rejected instead of receiving an inferred
vendor multiplier.

## Scan lifecycle and performance

Scans run away from AppKit. Only the newest generation may publish; forced
refresh cancels/replaces an older generation, local rows publish once, cloud
results publish as a second phase, and the last valid cloud snapshot survives a
temporary failure. tmux is sampled once per scan.

Performance varies with the machine and local session set. Measure the release
build against the target machine rather than relying on a published workstation
number:

```bash
dist/Antarium.app/Contents/MacOS/Antarium --bench
```

Persistent caches are `~/.antarium/transcripts-v5.json` and
`~/.antarium/harness-cache-v2.json`.

CI also generates a 20,000-record JSONL transcript. Its default 5-second cold
budget is intentionally a catastrophic-regression guardrail, not a speed claim.
Algorithmic assertions are stricter: cold scans must report the exact source
bytes and records, warm scans zero parsed bytes/records, and an append scan only
the exact appended bytes and records.

## Roadmap ideas

- Continuously validate every shipped harness against upstream application
  releases and publish a compatibility matrix with the exact evidence date.
- Add an SDK-backed harness generator and validator so third parties can create
  file, JSONL, SQLite, process, command, and UI-tab integrations without editing
  JSON by hand.
- Introduce additive descriptor primitives only when at least two harnesses need
  them, keeping agent-specific facts in configuration and executable control
  flow in Swift.
- Add safe harness update channels with schema migration previews, diffs, and
  rollback for user-modified descriptors.
- Add an Xcode UI-test host for automated accessibility audits and keyboard-only
  end-to-end coverage.
- Publish signed, notarized releases and a verified update feed after the bundle
  identity, Developer Program team, and release-signing policy are final.
- Add privacy-preserving diagnostics export that redacts credentials, prompts,
  raw command arguments, usernames, and home-directory paths by default.

The maintained baseline and prioritization notes are in [Roadmap.md](Roadmap.md).

## Privacy and trust boundary

Antarium runs locally and does not include telemetry. It reads process metadata,
configured session stores, and provider credentials needed for quota requests.
Raw credentials, prompts, transcripts, and command arguments must never be
written to Antarium metadata or committed as fixtures.

Antarium's built-in dashboard and bundled harnesses are read-only with respect
to external work. They may focus or attach to a terminal or tmux pane, but do
not terminate agent processes, terminal applications, tmux clients, or tmux
sessions. Repository tests enforce both the UI boundary and the bundled-command
allowlist.

Harness files are trusted local configuration. A harness may read declared
files or SQLite databases and may launch a declared command without a shell.
That executable runs with the user's permissions and can have side effects, so
a custom command harness is outside the bundled read-only guarantee. Review
third-party harnesses before installing them. See [SECURITY.md](SECURITY.md) for
the reporting process and security model.

## Distribution

Local builds use an ad-hoc signature. Public distribution can use a Developer
ID identity and an Apple notarytool keychain profile:

```bash
CODESIGN_ID="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="antarium-notary" \
VERSION="0.2.0" ./build.sh --notarize
```

The pipeline performs a clean release build, bundles every schema/fixture,
signs with the hardened runtime and timestamp, verifies the plist/signature,
submits and waits for notarization, staples and validates the ticket, runs a
Gatekeeper assessment, recreates the archive from the stapled app, and writes
its SHA-256. Apple credentials are not accepted as command-line arguments or
stored by the repository.

## Diagnostics

```bash
BIN=dist/Antarium.app/Contents/MacOS/Antarium
$BIN --agents                  # local session rows and source health
$BIN --bench                   # three scans in one process
$BIN --once                    # quota providers and errors
$BIN --once claude-code        # one provider
$BIN --preview /tmp/sheet.png  # light/dark rendering sheet
$BIN --verify-harness-fixtures # deterministic bundled compatibility suite
```

Logs default to warnings at `~/.antarium/logs/antarium.log`. Set
`ANTARIUM_LOG=debug` or `"logLevel": "debug"` for more detail.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and do
not submit real account data, credentials, transcript content, or extracted
third-party application artwork. Synthetic tests and fixtures are intentionally
kept public because they enforce numeric integrity without exposing user data.

## License

Antarium is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Noncommercial use, study,
modification, and distribution are permitted under its terms. Commercial use
requires a separate license from the copyright holder.
