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

Synthetic is the first descriptor-backed provider that is a proper meter
with a reset: the subscription states a request ceiling, the requests
spent against it and when it renews. The renewal is read from the
response rather than inferred from a period length, which is the
difference between a row that stays right after a plan change and one
that is right until somebody changes plan. The figures are requests
rather than tokens, because that is how the service bills.

OpenRouter is charted as spend against purchases. Its credits endpoint
reports two lifetime figures — everything ever added and everything ever
spent — and no remaining balance, so the meter is the ratio of the two:
empty after a top-up, full when the credits are gone. The key is read
from a file rather than from `OPENROUTER_API_KEY`, because the endpoint
answers 403 to an ordinary inference key and only a management key
works; reading the conventional variable would take the key most people
have and fail with it for ever, which is the degraded shipping this
document rules out two paragraphs below.

Five more were looked at and not written, for one reason between them: the
endpoint is known and the response is not. Chutes publishes
`GET /users/me/quotas` and `GET /users/me/subscription_usage` in its API
reference and says "schema not detailed" for both. DeepInfra's balance and
usage calls appear in other tools but in none of DeepInfra's own
documentation. Antigravity's field paths are reverse-engineered from the
binary by the projects that carry them, whose own notes say the shape may
change without notice.

Codebuff's own documentation has no usage endpoint in it at all, and Poe's
balance call is named by every tool that reads it and by none of Poe's pages.

A mapping written from another tool's source is a guess about somebody else's
product that happens to work today, and the fixture beside it would prove
only that the guess is self-consistent. One real payload each is the whole
of what is missing, and it is worth more than any amount of reading around
it.

Checked again on 2026-09-22, against the vendors' own references rather than
against this list. DeepInfra's API reference documents its OpenAI-compatible
and native inference endpoints and no account, billing or balance endpoint
of any kind; the balance path that circulates does so in other projects'
pull requests, which is the whole of the objection. Poe's own API
documentation describes chat completions and responses and no endpoint for
reading a compute-point balance. Both verdicts stand, and stand on evidence
now rather than on this paragraph.

Chutes was re-checked on 2026-09-22 and the entry above holds, now for a
reason that is established rather than repeated. The users reference does
document `GET /users/me/quotas`, with a Bearer token, and the machine-
readable index beside it lists the same path as "account limits and usage".
Neither states a single field the response contains. So the endpoint is
published and its shape is not, which is precisely the case this section is
about: a descriptor is field paths, and there are none to read.

This is the entry most worth revisiting, because it is one page away from
being writable. A published example response — or one real reply from an
account — is the whole of what is missing.

A whole class was blocked by our own scheme check rather than by anything a
vendor does. A self-hosted proxy in front of an agent — LiteLLM, and the
several like it — documents its spend endpoint properly and serves it over
http on a port, because it is listening on loopback. Requiring https refused
every one of them, and the only way round it was a certificate in front of a
local socket. Plaintext to this machine is accepted now, which is a thing our
code decides rather than a schema somebody else has to publish.

One more thing stood between that and a working descriptor, and it was
ours: `--check` kept its own copy of the endpoint rule and insisted on
https, so the self-hosted case the runtime accepts was reported as broken by
the tool whose whole job is telling an author whether theirs works. Both
read one predicate now.

What still stops LiteLLM specifically is smaller and is the user's to fix:
its endpoint is a host and port only they know, and `/key/info` wants the
master key in the header and the key being asked about in the query. A
shipped descriptor cannot carry a working default for either, so this is a
thing to document for somebody writing their own rather than to ship.

Documented now, and the two-secret problem turned out not to need a second
credential: the key being watched is not a secret from the person watching
it, so it goes in their own descriptor while the master key stays in the
keys folder. The worked example in docs/TECHNICAL.md is decoded, checked
and mapped by the test suite, against the reply LiteLLM's own pages show.
`/spend/keys` would take one secret rather than two and is not used: its
response shape is not published, and the shape of a structurally similar
endpoint is the guess this document exists to refuse.

The second half of that was wrong for longer than it looked. "Document it
for somebody writing their own" assumed they could, and they could not:
`{token}` was substituted into headers and into a POST body but not into the
endpoint, so a credential belonging in the query had nowhere to go. The
class was undescribable by anybody, not merely unshippable by us. It is
substituted there now, percent-encoded, and the authoring guide says so.

Fireworks is the exception that failed differently: it publishes a complete
schema for `GET /v1/accounts/{account_id}/quotas`, and still does not fit.
The path carries an account id this app has no way to learn — a descriptor
declares one endpoint, not a call to discover the identifier for the next —
and the quotas themselves are reserved GPU capacity rather than spend, so a
serverless account has none. Worth recording because the first half will
recur: plenty of vendors scope usage under an account or organisation id, and
until a descriptor can name where to find one, a published schema is not
enough on its own.

A descriptor can name one now, for the case that actually occurs: the id is
written beside the token, which is where the Codex provider reads its own
from, so `quota.credential.accountField` takes it out of the file the
credential already opens and `{account}` goes wherever `{token}` does. A
discovery call — asking one endpoint for the identifier of the next — is a
different thing and still is not possible. Fireworks itself remains out for
its other reason: the quotas are reserved GPU capacity rather than spend, so
a serverless account has none to report.

Not currently integrated, with the reason each would need native code — or,
for the first, the reason it still cannot be written even though it no longer
would. The
table is the answer to "add every provider some other tool supports", and it
is worth reading before starting one: a mapping being expressible is not the
same as a provider being shippable, and the difference is almost always the
credential rather than the response.

| Service | Why a descriptor cannot express it |
| --- | --- |
| Antigravity | the reason moved. Its embedded language server began refusing every tokenless request once the `agy` CLI stopped publishing the CSRF token it generates, so the port-probing route other tools used is closed to them too; the working path is now `agy -p /usage --output-format json`. A descriptor can express that — `quota.command` reads its figures from a program's stdout — so the blocker is no longer the access. What is missing is the mapping: the field paths are reverse-engineered from the binary by the tools that carry them, and their own documentation says the shape may change without notice. One real payload would be enough to write the descriptor and its fixture, and nothing short of that should be written |
| Amazon Bedrock | requests must be SigV4-signed |
| Alibaba Model Studio | authentication is a browser cookie |
| Mistral | Vibe writes `~/.vibe/logs/session/session_<date>_<time>_<id>/meta.json`, which the `json` source kind could glob — so this is a session reader, not a quota one. The combined-figure half of this is no longer a reason: `map.totalTokens` exists now, drawn under its own icon rather than under the sent arrow, so a harness reporting one running count no longer has to choose between a wrong number and no number. That was a gap here rather than a fact about this agent, and it was recorded as the latter. What remains is a real payload: the path, the field names and whether the file carries a working directory are all unconfirmed, and one real `meta.json` is the whole of what is missing |
| Omp | `omp usage --json` is JSON and would map, but Oh My Pi is an aggregator: it manages OAuth accounts for Anthropic, Codex, Z.ai and others and reports every one. Adding it would show the same Claude window twice, once natively and once through it |
| Kimi | browser cookie by default. The POST half of this is no longer a reason: `quota.method` describes one now, and `roots` already reaches windows that nest. The cookie is what remains, and it is the whole of it |

A provider whose credential expires with no way to renew it is deliberately
left out rather than shipped degraded: a gauge that reads "sign in" most of the
time is worse than an agent the settings list simply does not offer. The same
reasoning already applies to Kimi's local endpoint, which only answers while
Kimi itself is running.

## Coverage against ClaudeBar's roster

The first ask for this app was to read every usage API ClaudeBar does, and
until this section existed there was no way to tell how far that had got. Every
part of this document above argues providers one at a time. That is the right
way to decide about any one of them and no way at all to notice one nobody
thought of — it can explain at length why something was declined while saying
nothing about a provider it did not know existed.

ClaudeBar's roster is a fact about somebody else's project, so it cannot be
derived from this one. It is written down as data instead, in
`Tests/AntariumTests/ClaudeBarCoverageTests.swift`, which names all twenty
providers ClaudeBar monitors and checks each against what ships here. When
ClaudeBar adds one, that list is what has to change, and until it does the
difference between "declined" and "never heard of" is a real difference again.

14 of the 20 are read for usage here. 2 more — Kimi and Oh My Pi — are
recognised and given rows without a usage API, for the reasons in the table
above; the remaining 4 are in that table too. This app also reads usage APIs
ClaudeBar does not, so the roster is a floor rather than a ceiling.

## Project context each agent understands

A row can report what a project gives its agent — instructions, memory,
skills, MCP servers, permissions — but only where the convention is written
down by the vendor and unambiguous enough to probe without guessing.

Described: every harness that puts a row on the dashboard.

<!-- capability-gap: none -->

That line is not prose. A test derives the harnesses that make rows and
declare no capabilities, and requires this marker to name exactly that set,
so adding a harness without capabilities fails until the marker admits it —
and closing the last gap could not be announced here without being true.

11 of the 25 never appear in it. Project context hangs off a row, and none of
those makes one: a quota-only harness like `copilot` or `zai` reads no session
source, and a focus-only one like `herdr` or `orca` reports panes that are
already somebody else's rows. A capability rule on either is
configuration nothing will ever read, so a second test refuses one.

What closing them took, each time, was the vendor's own statement of where
the files live — a convention taken from memory would report a capability the
agent never reads, or miss one it does. Two shapes made it harder than it
looks. A folder where only some names count needs `fileSuffixes`: Cursor
reads `.cursor/rules/*.mdc` and ignores a plain `.md` there, and Copilot's
scoped instructions must end `.instructions.md`, which is a suffix and not an
extension. And where an agent documents a chain rather than a set — Hermes
names six files and loads the first that matches; pi loads
`AGENTS.override.md` instead of `AGENTS.md` — the declared order is that
chain, because the probe returns the first path that matches and a wrong
order names a file the agent ignored.

What none of them declares is the walk. Most of these agents look up through
parent directories to a repository root, and several discover more files as
they read; the probe sees the session's working directory. A repository-wide
file read from a subdirectory reads as absent, which is the safer of the two
wrong answers, and each descriptor's note says so rather than approximating.
The same holds one level down: GitHub documents Copilot's scoped instructions
as living "within or below" `.github/instructions`, and a file in a subfolder
there is not counted.

## Positioning in one sentence

> Orchestrators run your agent team; Antarium shows supported agents across your
> Mac and keeps their activity and limits visible.

Sources: [Conductor harness overview](https://www.conductor.build/docs/reference/harnesses),
[Conductor isolated workspaces](https://www.conductor.build/docs/concepts/workspaces-and-branches),
[Conductor API](https://www.conductor.build/docs/api), and
[Zen product overview](https://vozen.io/).
