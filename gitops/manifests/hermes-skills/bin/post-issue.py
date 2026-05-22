#!/usr/bin/env python3
"""Hermes-side helper to POST a draft issue to issue-creator.

Reads JSON from sys.argv[1] (file path) matching the issue-creator
schema, signs with WEBHOOK_HMAC_SECRET, POSTs to ISSUE_CREATOR_URL,
prints the response. Hermes skills invoke this via the terminal toolset;
the secret lives in the Hermes pod's env (mounted via envFrom from a
copy of the webhook-hmac BitwardenSecret in the hermes namespace).

The file-path interface (rather than stdin) is deliberate: Hermes's
Tirith security scanner blocks `cat ... | python3 ...` patterns as
"pipe to interpreter" (MITRE T1059.004) — a real concern for `curl|sh`
attacks, but a false positive here. Two-step write-then-read avoids the
pattern entirely.

Usage from inside Hermes:
    cat > /tmp/issue.json <<'JSON'
    {"title":"...","body":"...","labels":["agent:queued","from:monitoring"],"dedupe_key":"alertmanager:Foo:bar"}
    JSON
    python3 /opt/data/agent-loop/bin/post-issue.py /tmp/issue.json

Exits 0 on 200/201, 1 otherwise. Prints the response JSON to stdout so
the agent can read it.
"""

import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("ISSUE_CREATOR_URL", "http://issue-creator.github-app:80/issues")
SECRET = os.environ["WEBHOOK_HMAC_SECRET"].encode()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: post-issue.py <path/to/issue.json>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = f.read()
        if not payload.strip():
            print(f"error: {path} is empty", file=sys.stderr)
            return 2
        # Round-trip parse to fail loud on malformed JSON before signing
        json.loads(payload)
    except FileNotFoundError:
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"error: invalid JSON in {path}: {exc}", file=sys.stderr)
        return 2

    body = payload.encode()
    sig = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        URL,
        data=body,
        headers={"Content-Type": "application/json", "X-Hub-Signature-256": sig},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(resp.read().decode())
            return 0
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}: {exc.read().decode()[:500]}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
