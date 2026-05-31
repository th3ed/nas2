#!/usr/bin/env bash
# Invariants for the news ingest pipeline:
#   1. The news-ingest CronJob exists
#   2. If any Job has run, the most recent one succeeded
#   3. If articles are populated, rows have non-empty content_hash + summary,
#      and the chunks + chunk_articles tables (new schema) have rows
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="news: ingest CronJob exists"
out=$(ssh_kubectl "-n news get cronjob news-ingest -o name") || {
    fail "$TITLE: $out"
    exit 1
}
if [[ "$out" != "cronjob.batch/news-ingest" ]]; then
    fail "$TITLE: unexpected: $out"
    exit 1
fi
pass "$TITLE"

TITLE="news: most-recent ingest Job succeeded (or none yet)"
ingest_jobs=$(ssh_kubectl "-n news get jobs --no-headers 2>/dev/null" | awk '$1 ~ /^news-ingest/' || true)
if [[ -z "$ingest_jobs" ]]; then
    pass "$TITLE: no Jobs yet (cron not fired)"
else
    latest=$(printf '%s\n' "$ingest_jobs" | sort -k4 | tail -1 | awk '{print $1}')
    completions=$(ssh_kubectl "-n news get job $latest -o jsonpath={.status.succeeded}")
    failed=$(ssh_kubectl "-n news get job $latest -o jsonpath={.status.failed}")
    if [[ "$completions" == "1" ]]; then
        pass "$TITLE: $latest succeeded"
    elif [[ "$failed" != "" && "$failed" != "0" ]]; then
        fail "$TITLE: $latest failed (succeeded=$completions failed=$failed)"
        ssh_kubectl "-n news logs job/$latest --tail=40" >&2
        exit 1
    else
        pass "$TITLE: $latest still running"
    fi
fi

TITLE="news: if articles populated, rows have content_hash + summary + chunks"
count=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT count(*) FROM articles WHERE extraction_status='ok';\"" | tr -d ' ')
if [[ -z "$count" || "$count" == "0" ]]; then
    pass "$TITLE: no articles ingested yet (skipped)"
else
    null_hash=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT count(*) FROM articles WHERE extraction_status='ok' AND (content_hash IS NULL OR content_hash='');\"" | tr -d ' ')
    null_summary=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT count(*) FROM articles WHERE extraction_status='ok' AND summary IS NULL;\"" | tr -d ' ')
    chunks=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT count(*) FROM chunks;\"" | tr -d ' ')
    chunk_links=$(ssh_kubectl "-n news exec postgres-0 -- psql -U postgres -tAc \"SELECT count(*) FROM chunk_articles;\"" | tr -d ' ')
    if [[ "$null_hash" != "0" || "$null_summary" != "0" || "$chunks" == "0" || "$chunk_links" == "0" ]]; then
        fail "$TITLE: count=$count null_hash=$null_hash null_summary=$null_summary chunks=$chunks chunk_links=$chunk_links"
        exit 1
    fi
    pass "$TITLE: $count articles, $chunks chunks, $chunk_links chunk_articles links"
fi
