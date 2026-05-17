# Agent-loop — Phase 0 verification results

Phase 0 of the autonomous agent loop (plan:
`/Users/ed/.claude/plans/i-want-to-use-majestic-peach.md`) gates four
verifications and a one-time GitHub App setup. Each check below has a
pass/fail line and the chosen mitigation if any.

Date: 2026-05-17
Cluster context: `nas2` (k3s, Ubuntu 24.04 host)

---

## Check 1 — OpenCode in a container drives LiteLLM end-to-end

**Result: PASS** (local + cloud paths both working).

Smoke test ran the `opencode` CLI v1.15.4 inside a Pod with the in-cluster
LiteLLM at `http://litellm.litellm:4000/v1` configured as a custom OpenAI-
compatible provider. Two scenarios:

- `litellm/gemma4:e4b` (Ollama on GPU via LiteLLM): the agent grep'd a
  buggy `calc.py`, read it, edited it (`a - b` → `a + b`), and attempted
  verification. Edit applied correctly.
- `litellm/claude-haiku-4.5` (OpenRouter via LiteLLM): created two files
  with exact content, no trailing newlines. Tool calls clean.

**Constraint discovered (significant — feeds Phase 2 design):** the bun
runtime that ships with OpenCode crashes with
`embedder failed to suspend thread … for TLC …` (exit 133, JavaScriptCore
GC fault) under the K8s default AppArmor profile. The minimum mitigation
is one annotation on the Pod (no `privileged`, no `SYS_PTRACE`, no
`seccomp: Unconfined`):

```yaml
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/<container-name>: unconfined
```

(Or, on K8s 1.30+, `securityContext.appArmorProfile.type: Unconfined`.)

Tested working image base: `oven/bun:1-debian`. Ubuntu 24.04 base requires
the same annotation; the bun runtime is the constraint, not the base OS.

Memory recorded:
`/Users/ed/.claude/projects/-Users-ed-projects-nas2/memory/project_opencode_apparmor.md`.

---

## Check 2 — LiteLLM `/v1/messages` (Anthropic-compat) preserves tool-use streaming

**Result: FAIL on `/v1/messages`; PASS on `/v1/chat/completions`.**

LiteLLM 1.82.3's `/v1/messages` endpoint mis-routes OpenRouter-backed
models. The bug: LiteLLM forwards the literal `openrouter/anthropic/...`
model string to OpenRouter, which only accepts `anthropic/...` (no
`openrouter/` provider prefix). Reproduced for `claude-haiku-4.5`; same
request via `/v1/chat/completions` strips the prefix correctly and works
fine.

```
POST /v1/messages    → 400  "openrouter/anthropic/claude-haiku-4.5 is not a valid model ID"
POST /v1/chat/completions → 200  (works for the same model)
```

Tool-call streaming via `/v1/chat/completions` was independently
verified:

- `claude-haiku-4.5`: 12 streamed chunks, `finish_reason=tool_calls`,
  clean JSON `{"city": "Tokyo", "units": "celsius"}`.
- `gemma4:e4b`: 2 chunks, `finish_reason=stop` (Ollama OpenAI-compat
  quirk; the gemma renderer doesn't set `tool_calls` in finish_reason),
  but the tool_call payload itself arrives valid.

**Mitigation:** the dev-agent and reviewer-agent configure OpenCode to
use the OpenAI-compat path (`baseURL: http://litellm.litellm:4000/v1`),
not Anthropic-style `/v1/messages`. The Phase 0 smoke test (Check 1)
already used this path successfully for both local and cloud models.
**No `ANTHROPIC_BASE_URL` env var** in agent containers — only
OpenAI-compat config.

---

## Check 3 — Presidio guardrail does not mangle source code

**Result: PASS** for verbatim read/echo.

Sent a code snippet through `claude-haiku-4.5` (Presidio-guarded path)
and `gemma4:e4b` (control, no guardrail) containing:

| Token type | Value | Cloud (Presidio) | Local (control) |
|---|---|---|---|
| Email | `edward@nas2.local` | PRESERVED | PRESERVED |
| Email | `alice@example.com` | PRESERVED | PRESERVED |
| Email | `bob.smith+work@example.org` | PRESERVED | PRESERVED |
| CIDR  | `10.42.0.0/24` | PRESERVED | PRESERVED |
| IP    | `192.168.1.50` | PRESERVED | PRESERVED |
| Phone | `+1-555-867-5309` | PRESERVED | PRESERVED |
| SSN-like | `123-45-6789` | PRESERVED | PRESERVED |

The mask-on-input + unmask-on-output cycle (`output_parse_pii: True`) is
working — placeholders round-trip identity-preserving. Edit-near-PII
behavior is structurally fine (placeholder identity preserved) but must
be re-observed during Phase 2 in real edit scenarios where the model
modifies content adjacent to a masked token.

No config change required.

---

## Check 4 — GitHub App token minting from a K8s Pod

**Result: DEFERRED.** Blocked on the one-time GitHub App setup.

Action items for the user (steps in
`/Users/ed/.claude/plans/i-want-to-use-majestic-peach.md` under
"GitHub App setup — step by step"):

1. Create the App at https://github.com/settings/apps/new
2. Install on the `th3ed/nas2` repo
3. Store app-id, installation-id, private-key in Bitwarden Secrets Manager
4. Hand over the three `bwSecretId`s; the BitwardenSecret manifest at
   `gitops/manifests/github-app/bitwarden-secret.yaml` will be wired
   from them.

Once the manifest syncs, run a one-shot Pod that mounts the App private
key, signs a JWT, calls
`POST /app/installations/{id}/access_tokens`, and confirms
`gh api user` accepts the resulting 1-hour token.

---

## Cost-control change shipped with Phase 0

- `tests/run-all.sh` now skips any file matching `test-paid-*.sh`.
- New `tests/run-paid.sh` runs only `test-paid-*.sh` with an interactive
  confirm prompt (`--yes-i-will-pay` skips the prompt).
- CLAUDE.md gained a "Cost controls for tests" subsection documenting
  the convention.

Audit of existing tests: all 13 are zero-cost. The single test that
calls a chat-completion endpoint (`test-hermes-gemma-tool-rewrite.sh`)
uses local `gemma4:e4b` via Ollama only. No tests were renamed; the
infrastructure is purely preventive.

---

## Verdict

| Check | Status | Blocker for Phase 1? |
|---|---|---|
| 1. OpenCode + LiteLLM end-to-end | PASS | No — design now includes AppArmor annotation |
| 2. LiteLLM Anthropic-compat tool streaming | PARTIAL (chat/completions PASS, messages FAIL) | No — agents use chat/completions only |
| 3. Presidio vs source code | PASS | No |
| 4. GitHub App token minting | DEFERRED | **Yes** — Phase 1 needs the App |
| Cost-control plumbing | DONE | n/a |

Phase 1 (monitoring + spec-driver) is unblocked except for the GitHub
App setup, which the user owns.
