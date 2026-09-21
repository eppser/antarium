# Where Antarium fits in the coding-agent ecosystem

Antarium is an observability companion, not another coding agent or workspace
orchestrator. It answers what is running, whether trustworthy evidence says it
is working or waiting, where the session lives, and what measured usage or
quota information is available.

## Product roles

| Product category | Primary responsibility | Relationship to Antarium |
|---|---|---|
| Agent orchestrators such as [Conductor](https://www.conductor.build/docs) | Create isolated workspaces, run agents, manage branches, diffs, checks, pull requests, and optionally cloud execution | Antarium can provide a quiet system-wide view alongside the orchestrator, especially when work also runs in terminals, tmux, editors, or other apps |
| Terminal agents such as [Zen](https://vozen.io/) | Read and edit code, run commands, and retain an agent session inside the terminal | Antarium does not replace the agent; a verified integration can make its activity visible with other supported sessions |
| Editors and agent hosts such as Cursor, Zed, VS Code, Warp, and tmux | Host coding sessions, terminals, tabs, panes, or editor-native agents | Antarium joins supported process and session evidence and can focus the existing host |
| Antarium | Observe supported sessions and provider quota across those environments | It does not create workspaces, edit code, merge branches, or terminate external sessions |

Conductor describes itself as the workspace layer above Claude Code, Codex,
Cursor, and OpenCode. Each task can receive its own branch, files, terminal,
diff, checks, and review path. Its local worktrees are development isolation,
not a security boundary; its cloud offering adds persistent remote execution,
multiplayer collaboration, and an API.

Zen is a local terminal coding agent. It performs the task itself, persists its
own sessions and memory, and can use local or hosted models. It is therefore an
agent Antarium could observe after compatibility is proven, not an alternative
monitoring dashboard.

## What is deliberately different

- Antarium is tool-neutral. It can present supported sessions launched outside
  any single orchestrator.
- Antarium is passive. Its built-in dashboard focuses existing sessions but
  does not stop agents, close terminals, or mutate repositories.
- Antarium emphasizes truthful observability. Missing data, a measured zero,
  and a failed collection remain different states.
- Antarium keeps agent-specific facts in reviewable JSON integration
  descriptors and offers a typed SDK for generating them.
- Antarium is MIT licensed and local-first, with no Antarium telemetry or
  prompt collection.

## Current integration status

Antarium does not currently ship a dedicated Conductor or Zen integration.
Existing Claude Code, Codex, Cursor, and OpenCode integrations may recognize an
underlying session only when its process and session evidence matches their
tested descriptors. That is not a blanket compatibility promise for sessions
embedded in another product.

A future Conductor integration should use configuration for executable paths,
workspace metadata, presentation, and deep-link facts. Authenticated cloud API
access, bounded polling, cancellation, and lifecycle transitions belong in
native control flow. Conductor's API documentation notes that a newly queued
prompt can report `idle` before it ever reports `working`; an adapter must
observe `working` or a new reply before interpreting a later `idle` as finished.
The API is also marked beta, so its response contract needs dated fixtures and
failure-closed parsing.

A future Zen integration should begin with documented or reproducible process
and session-storage evidence. It should ship only after synthetic fixtures prove
identity, working/waiting transitions, installation layouts, and the absence of
helper-process collisions.

## Which quota providers can be descriptors

A descriptor makes one authenticated GET and maps the reply. That covers more
services than it sounds like, and not the ones whose difficulty is in getting
the token rather than reading the answer. The distinction is worth writing down,
because "add every provider some other tool supports" is a reasonable-sounding
request whose honest answer is "about half of them, and the rest are each a
separate piece of Swift".

Shipping as descriptors, each with a recorded response shape under
`Resources/quota-fixtures`: GitHub Copilot, Z.ai GLM, MiniMax, OpenCode Zen,
Command Code, Vercel AI Gateway, DeepSeek.

Native, because a descriptor cannot express them: Claude Code (Keychain and
OAuth refresh), Codex, Cursor (token from the desktop app's SQLite store), Amp
and Kiro (the reply is text, not JSON, and both are scanned rather than matched
— stdout is bounded but not trusted, and a backtracking pattern is a way to
turn a long line into a hung menu bar; Kiro reports what has been used where
Amp reports what is left, which is worth knowing before reading either), Gemini, and Grok
(`~/.grok/auth.json` is keyed by `<issuer>::<client-id>`, so the entry is found
by looking rather than by a path, and the refresh token is spent here because
no CLI reissues it — against the issuer the credential itself names, checked
to be an x.ai host first, since a bearer token must not be posted to whatever
a file says. The refreshed token is held in memory and never written back:
rewriting another application's credential file to save a round trip is a
poor trade against racing its own writes) — its access token lasts about an hour, and renewing it means running
the CLI and letting it rewrite `~/.gemini/oauth_creds.json`. The mapping alone
was written as a descriptor first and reverted, because a correct mapping
behind a credential that expires is exactly what the note below says not to
ship.

Not currently integrated, with the reason each would need native code. The
table is the answer to "add every provider some other tool supports", and it
is worth reading before starting one: a mapping being expressible is not the
same as a provider being shippable, and the difference is almost always the
credential rather than the response.

| Service | Why a descriptor cannot express it |
| --- | --- |
| Antigravity | usage comes from a local server on a discovered port behind a CSRF token |
| Amazon Bedrock | requests must be SigV4-signed |
| Alibaba Model Studio | authentication is a browser cookie |
| Mistral | usage comes from Vibe session logs rather than any endpoint, so it is a session reader rather than a quota one |
| Omp | `omp usage --json` is JSON and would map, but Oh My Pi is an aggregator: it manages OAuth accounts for Anthropic, Codex, Z.ai and others and reports every one. Adding it would show the same Claude window twice, once natively and once through it |
| Kimi | browser cookie by default; the server endpoint is a POST whose windows nest two levels deep |

A provider whose credential expires with no way to renew it is deliberately
left out rather than shipped degraded: a gauge that reads "sign in" most of the
time is worse than an agent the settings list simply does not offer. The same
reasoning already applies to Kimi's local endpoint, which only answers while
Kimi itself is running.

## Positioning in one sentence

> Orchestrators run your agent team; Antarium shows supported agents across your
> Mac and keeps their activity and limits visible.

Sources: [Conductor harness overview](https://www.conductor.build/docs/reference/harnesses),
[Conductor isolated workspaces](https://www.conductor.build/docs/concepts/workspaces-and-branches),
[Conductor API](https://www.conductor.build/docs/api), and
[Zen product overview](https://vozen.io/).
