#!/usr/bin/env bash
# Invariants for the news-rag Postgres backing store:
#   1. news-rag namespace exists and the Postgres StatefulSet pod is Ready
#   2. pgvector extension is installed in the default database
#   3. Expected schema (articles, article_chunks, ingest_state) is applied
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news-rag: postgres pod ready"
out=$(ssh_kubectl "-n news-rag get pods --no-headers") || {
    fail "$TITLE: kubectl get pods failed: $out"
    exit 1
}
ready=$(printf '%s\n' "$out" | awk '/^news-rag-postgres-/ && $2 ~ /1\/1/ && $3 == "Running"' | wc -l | tr -d ' ')
if [[ "$ready" != "1" ]]; then
    fail "$TITLE: news-rag-postgres-0 not Ready"
    printf '%s\n' "$out" >&2
    exit 1
fi
pass "$TITLE"

TITLE="news-rag: pgvector extension installed"
ext=$(ssh_kubectl "-n news-rag exec news-rag-postgres-0 -- psql -U postgres -tAc \"SELECT extname FROM pg_extension WHERE extname='vector';\"")
if [[ "$ext" != *"vector"* ]]; then
    fail "$TITLE: expected 'vector' in pg_extension, got: $ext"
    exit 1
fi
pass "$TITLE"

TITLE="news-rag: schema applied (articles, article_chunks, ingest_state)"
tables=$(ssh_kubectl "-n news-rag exec news-rag-postgres-0 -- psql -U postgres -tAc \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;\"")
for t in articles article_chunks ingest_state; do
    if ! printf '%s\n' "$tables" | grep -qx "$t"; then
        fail "$TITLE: missing table '$t'. Got: $tables"
        exit 1
    fi
done
pass "$TITLE"
