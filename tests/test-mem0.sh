#!/usr/bin/env bash
# Invariants for the Mem0 long-term memory stack:
#   1. mem0 namespace + Postgres StatefulSet + mem0-mcp Deployment are healthy
#   2. The mem0-mcp pod's MCP endpoint answers on /mcp/
#   3. End-to-end roundtrip: write a fact via the mem0-mcp MCP server's
#      underlying tool, then search it back (proves Mem0 + pgvector +
#      LiteLLM-embeddings wiring all work together)
#
# Free tier — no paid models touched. Uses gemma4:e4b for LLM
# extraction and ollama/nomic-embed-text for embeddings, both via
# LiteLLM.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="mem0: namespace and workloads ready"
out=$(ssh_kubectl "-n mem0 get pods --no-headers") || {
    fail "$TITLE: kubectl get pods failed: $out"
    exit 1
}
# Want exactly the Postgres StatefulSet pod + the mem0-mcp Deployment pod
# both Running and Ready.
postgres_ready=$(printf '%s\n' "$out" | awk '/^mem0-postgres-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
mcp_ready=$(printf '%s\n' "$out" | awk '/^mem0-mcp-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$postgres_ready" != "1" || "$mcp_ready" != "1" ]]; then
    fail "$TITLE: postgres_ready=$postgres_ready mcp_ready=$mcp_ready (expected 1,1)"
    printf '%s\n' "$out" >&2
    exit 1
fi
pass "$TITLE"

TITLE="mem0: MCP endpoint responds"
# The streamable-http transport answers GET on /mcp/ even without proper
# session headers — it returns 4xx/5xx body but with a parseable HTTP
# response. We just need a non-empty answer that proves the server is up.
body=$(ssh_kubectl "exec -n agentregistry deploy/agentregistry -- wget -qO- --timeout=10 http://mem0-mcp.mem0:8080/mcp/ 2>&1") || true
# Fall back to a debug pod if the registry container has no wget. Use a
# busybox image that we know ships wget; --rm cleans up on exit.
if [[ -z "$body" ]]; then
    body=$(ssh_kubectl "run mem0-probe-$$ --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
        wget -qO- --timeout=10 http://mem0-mcp.mem0:8080/mcp/ 2>&1")
fi
# Any non-empty response from /mcp/ proves the server is binding and
# routing; an empty body would mean the pod isn't accepting connections.
if [[ -z "${body// /}" ]]; then
    fail "$TITLE: empty body from http://mem0-mcp.mem0:8080/mcp/"
    exit 1
fi
pass "$TITLE"

TITLE="mem0: end-to-end add+search roundtrip"
# Drive the Mem0 library directly from inside the mem0-mcp pod (rather
# than over MCP, which would require negotiating a session). Same code
# path as the MCP tools, smaller test surface.
#
# base64-encoded so multiple layers of shell (laptop → ssh → kubectl exec
# → /bin/sh -c) don't mangle quotes inside the Python script.
script=$(cat <<'PY'
import json, os, sys
sys.path.insert(0, "/pkg")
from mem0 import Memory

config = {
    "vector_store": {
        "provider": "pgvector",
        "config": {
            "host": os.environ["MEM0_PG_HOST"],
            "port": int(os.environ.get("MEM0_PG_PORT", "5432")),
            "dbname": os.environ.get("MEM0_PG_DB", "postgres"),
            "user": os.environ.get("MEM0_PG_USER", "postgres"),
            "password": os.environ["POSTGRES_PASSWORD"],
            "collection_name": "memories",
            "embedding_model_dims": int(os.environ.get("MEM0_EMBED_DIMS", "768")),
        },
    },
    "llm": {
        "provider": "openai",
        "config": {
            "model": os.environ.get("MEM0_LLM_MODEL", "gemma4:e4b"),
            "openai_base_url": os.environ["LITELLM_BASE_URL"],
            "api_key": os.environ["LITELLM_API_KEY"],
        },
    },
    "embedder": {
        "provider": "openai",
        "config": {
            "model": os.environ.get("MEM0_EMBED_MODEL", "text-embedding-3-small"),
            "openai_base_url": os.environ["LITELLM_BASE_URL"],
            "api_key": os.environ["LITELLM_API_KEY"],
            "embedding_dims": int(os.environ.get("MEM0_EMBED_DIMS", "768")),
        },
    },
}
m = Memory.from_config(config)
uid = "mem0-test-roundtrip"
m.add(messages=[{"role": "user", "content": "The test fact is purple-elephant-42."}], user_id=uid)
hits = m.search(query="purple elephant", user_id=uid, limit=5)
results = hits.get("results", hits) if isinstance(hits, dict) else hits
found = any("purple-elephant-42" in (h.get("memory") or "") for h in results)
# Best-effort cleanup so repeat test runs start clean.
try:
    for h in results:
        if h.get("id"):
            m.delete(memory_id=h["id"])
except Exception:
    pass
print(json.dumps({"found": found, "count": len(results)}))
PY
)
b64=$(printf '%s' "$script" | base64 | tr -d '\n')
out=$(ssh_kubectl "exec -n mem0 deploy/mem0-mcp -- /bin/sh -c 'echo $b64 | base64 -d | python'" 2>&1) || {
    fail "$TITLE: python invocation failed"
    printf '%s\n' "$out" >&2
    exit 1
}
last=$(printf '%s\n' "$out" | tail -n 1)
case "$last" in
    *'"found": true'*) pass "$TITLE" ;;
    *)
        fail "$TITLE: roundtrip did not find the seeded fact"
        printf '%s\n' "$out" >&2
        exit 1
        ;;
esac
