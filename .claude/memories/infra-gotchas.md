# Infrastructure gotchas (May 2026)

Non-obvious bugs resolved this month. Each entry has the symptom, root cause, and fix so future debugging can pattern-match quickly.

---

## 1. sm-operator delta-sync skips new Bitwarden secret mappings

**Symptom:** Adding a new `bwSecretId` to an existing `BitwardenSecret` has no effect. Operator logs `No changes to <ns>/<name>. Skipping sync.`

**Root cause:** The operator calls Bitwarden's `secrets-modified-since-lastSyncTime` delta API *before* checking whether the materialized K8s Secret actually contains the expected keys. If the new Bitwarden secret's `lastModifiedDate` predates `status.lastSuccessfulSyncTime`, the delta is empty and the operator bails out without fetching anything.

**Fix:** Clear the sync timestamp so the next reconcile does a full pull:
```bash
kubectl -n <ns> patch bitwardensecret <name> \
  --subresource=status --type=merge \
  -p '{"status":{"lastSuccessfulSyncTime":null}}'
```
Then restart any pod that consumes the Secret via `envFrom`. Restarting the operator pod alone does **not** help — the timestamp gate runs before any pod logic.

---

## 2. OLLAMA_NUM_CTX is not a valid Ollama env var (use OLLAMA_CONTEXT_LENGTH)

**Symptom:** Ollama silently loads every model with a 4096-token context window regardless of what's configured. Ollama logs show `truncating input prompt limit=4096 prompt=17899 keep=4 new=4096`. OpenClaw responses are poor quality and chat sessions compact after 2–3 turns.

**Root cause:** `OLLAMA_NUM_CTX` is not recognized by Ollama ≥ 0.6. The server ignores it and falls back to the 4096-token default. OpenClaw's agent system prompt alone is ~18K tokens, so every prompt was being truncated to its last 4096 tokens — losing tool definitions and instructions.

**Fix:** Use `OLLAMA_CONTEXT_LENGTH` in `gitops/manifests/ollama/values.yaml`. Also set `OLLAMA_KEEP_ALIVE=24h` so an idle gap doesn't force a cold model reload. OpenClaw's `contextWindow` declaration in `configmap.yaml` must match the Ollama server value or compaction triggers too early.

---

## 3. auth-profiles.json must use the v1 store schema

**Symptom:** Every model call fails with `No API key found for provider "ollama-local"` even though the provider is declared in `openclaw.json`.

**Root cause:** The init container was writing `{"ollama-local":{"apiKey":"ollama"}}` (a flat map). The `AuthProfileStore` reader (`profiles-BvYdgqiN.js`) expects a versioned envelope: `store.profiles` must be an object keyed by `<provider>:<profileId>`. A flat map leaves `store.profiles` undefined and every lookup fails.

**Fix:** Write the v1 shape:
```json
{"version":1,"profiles":{"ollama-local:default":{"type":"api_key","provider":"ollama-local","key":"ollama"}}}
```
The init container now rewrites this unconditionally on every pod start (no file-existence guard) so stale wrong-shape JSON can't persist across format changes. Source of truth for the schema: `AuthProfileStore` in `/app/dist/profiles-BvYdgqiN.js` inside the container.

---

## 4. gateway.trustedProxies must be set when auth.mode=trusted-proxy

**Symptom:** Gateway crashes at startup: `trusted-proxy requires gateway.trustedProxies to be configured with at least one proxy IP`.

**Root cause:** `auth.mode=trusted-proxy` requires an explicit CIDR allowlist of upstream proxies. OpenClaw refuses to start without it — there is no implied "trust all" default.

**Fix:** Add `trustedProxies: ["10.42.0.0/24"]` (k3s pod CIDR) to the gateway block in `configmap.yaml`. In this single-tenant cluster the only external path to the openclaw pod is through the Tailscale Operator Ingress proxy, which is also a pod in that CIDR, so trusting it doesn't widen the attack surface. See `gitops/manifests/openclaw/configmap.yaml`.

---

## 5. openclaw home directory is /home/node, not /root

**Symptom:** init container writes to `/root/.openclaw/…`; the main container reads from `/home/node/.openclaw/…`. Files written by the init container are never seen.

**Root cause:** The openclaw container runs as the `node` user (not root). Its `$HOME` is `/home/node`. Any volume mount or file path targeting `/root/.openclaw` lands in the wrong directory.

**Fix:** All volume mounts, init container writes, and `subPath` mounts must use `/home/node/.openclaw` as the base path. The PVC is mounted at `mountPath: /home/node/.openclaw` in both init and main containers.
