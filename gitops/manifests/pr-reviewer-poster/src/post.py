#!/usr/bin/env python3
"""pr-reviewer-poster — one-shot Job that takes a pr-reviewer-produced
JSON verdict and posts a GitHub PR review.

Architectural role: one of three token-holding Jobs (alongside
pr-pusher and issue-poster). Mints a 1h GitHub App installation token,
calls POST /repos/{owner}/{repo}/pulls/{N}/reviews with event=APPROVE
or REQUEST_CHANGES, then exits. No LLM, no shell-out to external
content, narrow on purpose.

Trust boundary: the input is /workspace/.review.json, written by the
pr-reviewer Job which never had a token. Worst case the reviewer could
have done is craft a malicious verdict. Defenses:
  - verdict MUST be exactly APPROVED or CHANGES_REQUESTED
  - summary length capped at 8KiB
  - blocking_issues/comments serialized into the review body (no inline
    comments in v1 — GH inline comments need diff-position offsets that
    we don't compute reliably from the model's line numbers; revisit
    later)
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from pathlib import Path

import jwt
import requests

LOG = logging.getLogger("pr-reviewer-poster")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

GH_APP_ID = os.environ["GH_APP_ID"].strip()
GH_APP_INSTALLATION_ID = os.environ["GH_APP_INSTALLATION_ID"].strip()
GH_APP_PRIVATE_KEY = os.environ["GH_APP_PRIVATE_KEY"]
REPO = os.environ.get("REPO", "th3ed/nas2")
PR_NUMBER = os.environ["PR_NUMBER"].strip()
WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
REVIEW = WORKSPACE / ".review.json"

MAX_SUMMARY = 8 * 1024
ALLOWED_VERDICTS = {"APPROVED", "CHANGES_REQUESTED"}


def mint_token() -> str:
    now = int(time.time())
    jwt_token = jwt.encode(
        {"iat": now - 60, "exp": now + 540, "iss": GH_APP_ID},
        GH_APP_PRIVATE_KEY,
        algorithm="RS256",
    )
    resp = requests.post(
        f"https://api.github.com/app/installations/{GH_APP_INSTALLATION_ID}/access_tokens",
        headers={"Authorization": f"Bearer {jwt_token}", "Accept": "application/vnd.github+json"},
        timeout=20,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def render_body(verdict: str, summary: str, blocking_issues: list[str], comments: list[dict]) -> str:
    lines = [f"**Verdict:** `{verdict}`", "", summary[:MAX_SUMMARY]]
    if blocking_issues:
        lines += ["", "**Blocking issues:**"]
        lines += [f"- {b}" for b in blocking_issues]
    if comments:
        lines += ["", "**Comments:**"]
        for c in comments:
            path = c.get("path", "?")
            line = c.get("line", "?")
            body = c.get("body", "")
            lines.append(f"- `{path}:{line}` — {body}")
    lines += ["", "_Posted by nas2 pr-reviewer agent. Human review still required to merge._"]
    return "\n".join(lines)


def main() -> int:
    if not REVIEW.is_file():
        LOG.error("FATAL: no review at %s", REVIEW)
        return 2
    try:
        data = json.loads(REVIEW.read_text())
    except json.JSONDecodeError as exc:
        LOG.error("FATAL: review.json is not valid JSON: %s", exc)
        return 3

    verdict = data.get("verdict")
    if verdict not in ALLOWED_VERDICTS:
        LOG.error("FATAL: invalid verdict %r (allowed: %s)", verdict, ALLOWED_VERDICTS)
        return 4
    summary = data.get("summary", "") or ""
    blocking = data.get("blocking_issues", []) or []
    comments = data.get("comments", []) or []
    if not isinstance(blocking, list) or not isinstance(comments, list):
        LOG.error("FATAL: blocking_issues/comments must be lists")
        return 4
    if verdict == "CHANGES_REQUESTED" and not blocking:
        LOG.error("FATAL: CHANGES_REQUESTED requires non-empty blocking_issues")
        return 4

    body = render_body(verdict, summary, blocking, comments)
    event = "APPROVE" if verdict == "APPROVED" else "REQUEST_CHANGES"

    token = mint_token()
    LOG.info("minted GH App token (ghs_…)")

    resp = requests.post(
        f"https://api.github.com/repos/{REPO}/pulls/{PR_NUMBER}/reviews",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        json={"event": event, "body": body},
        timeout=30,
    )
    if resp.status_code >= 300:
        LOG.error("review post failed: HTTP %d %s", resp.status_code, resp.text[:500])
        return 5
    review = resp.json()
    LOG.info("posted review id=%s state=%s on PR #%s", review.get("id"), review.get("state"), PR_NUMBER)
    (WORKSPACE / ".review-id").write_text(str(review.get("id", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
