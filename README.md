# Antarium

[![CI](https://github.com/eppser/antarium/actions/workflows/ci.yml/badge.svg)](https://github.com/eppser/antarium/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](https://github.com/eppser/antarium)

**See every coding agent. Know what is working. Stay ahead of your limits.**

Antarium is a lightweight macOS menu-bar app for people who run several coding
agents at once. It brings active sessions, status, context, cost estimates,
memory, and account limits into one quiet dashboard.

<p align="center">
  <img src="docs/assets/antarium-demo.gif" width="720" alt="Antarium showing coding-agent status and details from the macOS menu bar">
</p>

## Why Antarium?

Running agents across multiple harnesses, terminals, Warp tabs, tmux panes, and desktop apps gets
hard to follow quickly. Antarium gives you one place to answer:

- What is my quata
- Which agents are still working?
- Which ones are waiting for me?
- Where is each session running?
- How much context, memory, and estimated cost has it used?
- How close are my Claude, Codex, or Copilot limits?

Get notified when agent finish his work.
Click a session to return to its terminal, tmux pane, or host app.

## Features

- **One menu-bar view** showing your quota across different providers: Antrohpic, OpenAI, Githup Copilot, etc.
- **Working/waiting status** based on process and session evidence.
- **Multi-session awareness** for agents running in the same folder or app.
- **Context and usage visibility** without turning missing data into fake zeroes.
- **Terminal, Warp, tmux, and desktop-app detection.**
- **Quota monitoring** for supported Claude, Codex, Cursor, and GitHub Copilot accounts.
- **Project context indicators** for instructions, memory, skills, MCP, and permissions.
- **Local-first and private:** no Antarium telemetry and no prompt collection.
- **Extensible harnesses:** add or adapt an agent without changing the app.

## Supported tools

Antarium currently includes harnesses for:

- Claude Code
- Codex CLI and Codex Desktop
- Cursor CLI and Cursor
- OpenCode
- Kimi Code
- Pi
- Hermes
- Zed
- VS Code with Copilot Chat

Install detection covers documented npm, curl/native, Homebrew, direct binary,
app-bundle, interpreter, and Nix layouts where the upstream tool supports them.

## Quick start

Antarium currently builds from source. You need macOS 13 or newer and a Swift
5.9-compatible Xcode toolchain.

```bash
git clone https://github.com/eppser/antarium.git
cd antarium
./build.sh --install
```

The script builds, signs, verifies, installs, and launches
`/Applications/Antarium.app`. Look for the Antarium gauge in your menu bar.

To run the full project checks:

```bash
./test.sh
```

Signed and notarized downloadable releases are on the [roadmap](Roadmap.md).

## Great for

- Running several Codex or Claude sessions in parallel.
- Keeping long-running tmux agents visible while you work elsewhere.
- Finding the Warp tab or desktop app that owns a session.
- Comparing activity across different coding-agent products.
- Watching context pressure and account limits before they interrupt work.
- Building support for an internal or newly released agent harness.

## Trustworthy numbers

Antarium treats “missing,” “zero,” and “failed to read” as different states.
It does not invent quota, context, token, cost, or session values. Cost is
clearly presented as an estimate, and configuration changes are covered by
synthetic fixtures and installation evaluations in CI.

## Private by design

Antarium runs locally and has no telemetry. It reads configured process and
session metadata and uses existing provider credentials only when requesting
supported quota information. The built-in dashboard can focus sessions, but it
does not terminate agents, terminal applications, or tmux sessions.

Custom harnesses are trusted local configuration and should be reviewed before
installation. See [SECURITY.md](SECURITY.md) for the full trust model.

## Extend Antarium

Each integration is described by a JSON harness. Most agent-specific details—
process names, files, SQLite queries, field mappings, open tabs, and status—live
in configuration. A typed Swift SDK and JSON Schema are available for authors.

Start with the [technical and harness reference](docs/TECHNICAL.md) when you
want to add an agent, generate a harness with the SDK, inspect diagnostics, or
understand the architecture.

## Project links

- [Technical and harness reference](docs/TECHNICAL.md)
- [Roadmap](Roadmap.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

Antarium is available under the [MIT License](LICENSE).
