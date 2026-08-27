# Contributing to Antarium

Thank you for improving Antarium. The project favors evidence-backed behavior,
small generic primitives, and explicit failure over guessed data.

## Development setup

You need macOS 13 or later, Xcode with the Swift Testing framework, and a
Swift 5.9-compatible toolchain.

```bash
git clone https://github.com/eppser/antarium.git
cd antarium
./test.sh
./build.sh
```

The app is assembled at `dist/Antarium.app` with a local ad-hoc signature.

## Making a change

1. Add or adapt a failing test/evaluation before changing observable behavior.
2. Make the smallest change that satisfies the product invariants in
   [AGENTS.md](AGENTS.md).
3. If a harness field changes, update the SDK, schema, runtime validation,
   migration behavior, examples, synthetic fixtures, and tests together.
4. Run the required verification below.
5. Explain the evidence, tradeoffs, and any unsupported upstream format in the
   pull request.

Harness contributions should prefer existing generic file, JSONL, JSON, SQLite,
command, process, and selection mechanisms. Propose a new primitive only when it
has a bounded safety model and at least two plausible consumers.

## Privacy and fixture rules

Never submit real credentials, account responses, prompts, transcript content,
raw command arguments, usernames, home-directory paths, logs, database copies,
or screenshots containing private data. Build fixtures from synthetic records
and use `/fixture/...` paths or temporary directories.

Third-party application names may be used for interoperability, but do not
submit logos or other artwork extracted from installed applications. Antarium's
vector/initial fallbacks keep contributed harnesses functional without them.

## Verification

```bash
./test.sh
swift build --scratch-path /tmp/antarium-strict \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
./build.sh
```

For harness changes, run:

```bash
dist/Antarium.app/Contents/MacOS/Antarium --verify-harness-fixtures
dist/Antarium.app/Contents/MacOS/Antarium --check path/to/harness.json
```

The live `--check` result is the compatibility evidence for an installed
upstream application; a committed synthetic fixture proves only the captured
format and expected numbers.

## Contribution license

By submitting a contribution, you agree that it may be distributed under the
project's [MIT License](LICENSE).
