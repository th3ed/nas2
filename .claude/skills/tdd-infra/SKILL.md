---
name: tdd-infra
description: Test-driven workflow for homelab infrastructure changes. Invoked as /tdd-infra <request>. Writes a failing test first, implements the change in gitops/, runs the full suite, and commits only when green.
---

# TDD Infrastructure Workflow

Invoked as `/tdd-infra <change request>`.

## Steps — follow in order, no skipping

### 1. Write the test first

Before touching any `gitops/` file:
1. Identify which invariant the change creates, modifies, or removes.
2. Add or update the appropriate `tests/test-<name>.sh`. If the invariant is new, create a new file following the pattern of existing tests (source `lib.sh`, call `pass`/`fail`, exit 1 on failure).
3. Run the test to confirm it currently **fails** (for new behavior) or **passes** (to establish a baseline before a refactor). This is the red step.

```bash
bash tests/test-<name>.sh
```

If the test already passes before any change, it is not testing the right thing — revise it.

### 2. Implement the change

Edit files under `gitops/` (or `group_vars/`, `roles/`, etc. as appropriate). Follow the declarative workflow: changes go in git, Argo applies them — never `kubectl apply` as a permanent fix.

### 3. Run the full suite

```bash
tests/run-all.sh --retry 3
```

`--retry 3` re-runs the suite up to 3 times with 30 s backoff to let Argo sync. This handles timing races — it is not a license to re-apply the same fix multiple times.

### 4. Commit only when green

When all tests pass, commit `gitops/` changes **and** any test changes together:

```bash
git add gitops/ tests/
git commit -m "<description>"
git push origin main
```

### 5. If tests still fail after retries — new hypothesis, not same fix

If `run-all.sh --retry 3` exits non-zero:
- Do **not** re-apply a variation of the same fix.
- Diagnose: run `./.claude/skills/nas2-diag/scripts/diag.sh --service <name>` for the failing component, read logs, form a **new hypothesis** with evidence.
- Apply the new fix, re-run the suite.

This follows the Debugging discipline in CLAUDE.md.

## What counts as "a test"

- Each `tests/test-*.sh` tests exactly one invariant.
- Tests are cheap reads: SSH + kubectl, or local curl/file checks.
- Tests exit 0 (pass) or non-zero (fail) — no side effects on the cluster.

## Keeping tests current

The suite lives in `tests/` and must stay in sync with the cluster's declared behavior:
- New feature added → write a test for its invariant *as part of the same commit*.
- New failure pattern found during debugging → add a regression test before closing.
- Feature removed → delete its test.
