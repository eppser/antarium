# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository:

https://github.com/eppser/antarium/security/advisories/new

Do not include credentials, transcripts, account responses, or other user data
in a public issue. Include a minimal synthetic reproduction, affected commit or
version, impact, and suggested mitigation when possible.

## Supported code

Security fixes target the current `main` branch. Until signed releases and an
update channel exist, locally built snapshots are not a stable support line.

## Trust and data model

Antarium is a local macOS application. It reads configured process and session
evidence and may use credentials already stored by supported providers to make
their quota requests. It does not need credentials committed to this repository.

Harness descriptors are trusted local configuration, not a sandbox boundary.
Depending on their declared source, they can read files or SQLite databases,
make a quota request, or launch an argv command directly without a shell. Review
third-party harnesses before installation and restrict file permissions on
`~/.antarium/harnesses`.

Antarium metadata must not persist credentials, prompts, transcript text, or raw
command arguments. Diagnostics and fixtures should use synthetic values and
redact usernames, home paths, session identifiers, and account data.
