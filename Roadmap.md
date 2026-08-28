# Antarium roadmap

This file tracks work that remains after the architecture/configuration pass.
Implemented behavior belongs in the README and tests, not in a historical list
of guesses.

## Current baseline

- Harness-specific process, source, folder/path metadata, field mapping, tab
  selection, capabilities, status, and descriptor-backed quota behavior are
  configuration-owned.
- Claude's live registry and the built-in Claude/Codex authentication flows are
  native adapters because they join stateful OS/service behavior.
- Scan publication is generation-gated, cloud failures retain the last valid
  snapshot, and runtime source failures remain visible.
- Persistent fingerprints include descriptors, complete file sets, manifests,
  and SQLite WAL/SHM state.
- The public `AntariumHarnessSDK`, JSON Schema, `--check`, and Swift Testing
  contracts define the authoring surface.
- Token facts are repriced from a dated table with separate five-minute and
  one-hour cache-write rates.
- Harness format v1 has SDK/runtime migration from unversioned v0 and fails
  closed on future versions.
- Generic harnesses have dated executable fixtures; CI proves exact cold,
  warm, and append work and enforces a catastrophic cold-scan guardrail.
- JSON-file, SQLite, and command-based UI tab evidence are configuration-owned.
- Settings/dashboard controls expose keyboard and assistive-technology actions,
  and light/dark snapshot surfaces render in tests.
- Release automation supports Developer ID timestamping, archive hashes,
  notarization, stapling, Gatekeeper assessment, and local ad-hoc builds.

## Next high-value work

1. Continue live validation against each upstream agent release. Fixtures catch
   regressions in Antarium and captured formats; they cannot predict a private
   upstream storage change.
2. Add a stable, signed update channel once the project has its final bundle ID,
   Developer Program team, release repository, and update-signing policy.
3. Add XCUITest accessibility audits when the project adopts an Xcode UI-test
   host. SwiftPM currently verifies semantic labels/actions and rendered light/
   dark surfaces, but cannot run Apple's full application accessibility audit.
4. Add a v2 migration only when an actual incompatible semantic change exists;
   prefer additive v1 fields while they remain unambiguous.
5. Evaluate a dedicated Conductor adapter using dated synthetic fixtures for
   bundled executable layouts, workspace identity, deep links, and the API's
   queued-to-working-to-idle lifecycle. Do not ingest cloud transcripts when
   status and identity endpoints provide sufficient evidence.
6. Evaluate terminal agents such as Zen through the normal descriptor
   contribution path. Ship support only after process, storage, installation,
   status, and collision behavior have reproducible evidence.

## Deliberate non-goals

- Do not turn harness JSON into a scripting language. New generic primitives
  need at least two plausible consumers and a bounded safety model.
- Do not display inferred quota, fabricated context windows, or successful
  zeroes for failed sources.
- Do not persist prompts, raw command arguments, tokens, or transcript content
  in Antarium metadata.
