#!/usr/bin/env python3
"""Hermes-side helper to POST a draft issue to issue-creator.

Reads JSON on stdin matching the issue-creator schema, signs with
WEBHOOK_HMAC_SECRET, POSTs to ISSUE_CREATOR_URL, prints the response.
Hermes skills invoke this via the terminal toolset; the secret lives
in the Hermes pod's env (mounted via envFrom from a copy of the
webhook-hmac BitwardenSecret in the hermes namespace).

Usage from inside Hermes:
    echo '{"title":"...","body":"...","labels":["agent:queued","from:monitoring"],"dedupe_key":"alertmanager:Foo:bar"}' \\
        | python3 /opt/data/agent-loop/bin/post-issue.py

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
    try:
        payload = sys.stdin.read()
        if not payload.strip():
            print("error: no JSON on stdin", file=sys.stderr)
            return 2
        # Round-trip parse to fail loud on malformed JSON before signing
        json.loads(payload)
    except json.JSONDecodeError as exc:
        print(f"error: invalid JSON on stdin: {exc}", file=sys.stderr)
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
