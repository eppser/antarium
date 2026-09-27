#!/usr/bin/env python3
"""Ask every usage endpoint this app talks to whether it is still there.

Sends one request per endpoint, built from the shipped descriptors, with a
deliberately invalid credential. No account data is read or sent: the token is
the literal string below, and nothing is written anywhere.

What the status tells you:

  401, 403  the path is alive, the method is accepted, the credential is
            refused. This is what `UsageHTTP` turns into `needsAuth`, and it is
            the answer to want.
  404       the path has moved. The provider reports nothing and no fixture can
            see it, because a fixture replays a recorded body.
  405       the method is wrong.
  400       the body or a required header is wrong.
  200       the service reports a rejected credential in the *body*. Two do —
            MiniMax and Z.ai — and `quota.needsAuthWhen` is how a descriptor
            says so. For those the body is fetched and the declared rule applied
            to it, so this reports whether the rule still recognises what the
            service actually sends. A service that changes its error code is the
            case that would otherwise go unnoticed: the app would go back to
            telling the user it could not read the reply.

This is deliberately not part of `./test.sh` or `./verify.sh`. Those run offline
in a fresh checkout, and a gate that fails when somebody else's service is down,
or that sends a request to eleven companies on every run, is a gate people learn
to ignore. Run it when a mapping is added or when a provider reports nothing.

    python3 tools/probe-endpoints.py

The native providers' endpoints are listed separately because they live in Swift
rather than in a descriptor; the comment beside each names the file.
"""
import json
import glob
import os
import subprocess
import sys

TOKEN = "antarium-invalid-probe-token"
ACCOUNT = "antarium-invalid-account"
TIMEOUT = "15"

# Endpoints held in Swift rather than in a harness file. Kept here so the sweep
# is every endpoint the app talks to rather than most of them.
NATIVE = [
    ("claude-code", "GET", "https://api.anthropic.com/api/oauth/usage",
     {"Authorization": f"Bearer {TOKEN}", "anthropic-beta": "oauth-2025-04-20"}, None, None),
    ("codex", "GET", "https://chatgpt.com/backend-api/wham/usage",
     {"Authorization": f"Bearer {TOKEN}"}, None, None),
    ("cursor", "POST",
     "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
     {"Cookie": f"WorkosCursorSessionToken={TOKEN}", "Content-Type": "application/json"}, "{}", None),
    ("grok", "GET", "https://cli-chat-proxy.grok.com/v1/billing",
     {"Authorization": f"Bearer {TOKEN}"}, None, None),
    ("gemini", "POST", "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
     {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}, "{}", None),
]


def fill(text):
    return text.replace("{token}", TOKEN).replace("{account}", ACCOUNT)


def lookup(value, path):
    """`a.b.c` into nested objects. The shipped rules are dotted, not filtered."""
    for key in path.split("."):
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value


def comparable(value):
    """The text a descriptor writes for a value, matching `FieldPath.comparable`."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else str(value)
    return None


def recognised(rule, body):
    """Whether a declared `needsAuthWhen` matches this body. Conjunction."""
    if not rule:
        return None
    return all(comparable(lookup(body, key)) == want for key, want in rule.items())


def fetch(method, url, headers, body):
    argv = ["curl", "-s", "--max-time", TIMEOUT, "-X", method]
    for key, value in headers.items():
        argv += ["-H", f"{key}: {value}"]
    if body is not None:
        argv += ["--data", body]
    argv.append(url)
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=40)
        return json.loads(done.stdout)
    except Exception:
        return None


def descriptor_requests(root):
    """One request per shipped descriptor that declares an endpoint."""
    out = []
    for path in sorted(glob.glob(os.path.join(root, "Resources/harnesses/*.json"))):
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
        quota = document.get("quota") or {}
        endpoint = quota.get("endpoint")
        if not endpoint:
            continue
        method = (quota.get("method") or "GET").upper()
        headers = {k: fill(v) for k, v in
                   (quota.get("headers") or {"Authorization": "Bearer {token}"}).items()}
        body = None
        if method == "POST":
            merged = dict(quota.get("body") or {})
            merged.update(quota.get("bodyList") or {})
            body = json.dumps({k: fill(v) if isinstance(v, str) else v
                               for k, v in merged.items()})
        out.append((document["id"], method, fill(endpoint), headers, body,
                    quota.get("needsAuthWhen")))
    return out


def probe(method, url, headers, body):
    argv = ["curl", "-s", "-o", os.devnull, "-w", "%{http_code}",
            "--max-time", TIMEOUT, "-X", method]
    for key, value in headers.items():
        argv += ["-H", f"{key}: {value}"]
    if body is not None:
        argv += ["--data", body]
    argv.append(url)
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return "timeout"
    return (done.stdout or "").strip() or "no reply"


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    requests = descriptor_requests(root) + NATIVE
    alive, attention = 0, []
    for name, method, url, headers, body, rule in requests:
        status = probe(method, url, headers, body)
        note = ""
        if status in {"401", "403"}:
            alive += 1
        elif status == "200":
            # The body decides. A declared rule that still matches is handled;
            # one that no longer matches is the case worth shouting about,
            # because the app has quietly gone back to blaming itself.
            reply = fetch(method, url, headers, body)
            if reply is None:
                note = "  <- answered 200 with no JSON this could read"
                attention.append(name)
            elif rule is None:
                note = "  <- reports rejection in the body; needs quota.needsAuthWhen"
                attention.append(name)
            elif recognised(rule, reply):
                alive += 1
                note = f"  rejection recognised by needsAuthWhen {json.dumps(rule)}"
            else:
                note = (f"  <- needsAuthWhen {json.dumps(rule)} no longer matches "
                        "what this service sends")
                attention.append(name)
        else:
            note = "  <- look at this"
            attention.append(name)
        print(f"  {name:16} {method:5} {status:8}{note}")
    print(f"\n{alive} of {len(requests)} refused the credential and said so readably.")
    if attention:
        print("needs attention: " + ", ".join(sorted(set(attention))))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
