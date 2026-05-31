#!/usr/bin/env bash
# Invariant: the news MCP tools return a point-in-time envelope
# {query_window, as_of, is_historical, results} for both get_briefing
# and search_articles, and is_historical correctly flips when the
# query window ends >6h ago.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pod=$(ssh_kubectl "-n news get pods -l app.kubernetes.io/component=mcp -o name" | head -1)
pod=${pod#pod/}
if [[ -z "$pod" ]]; then
    fail "news: no news-mcp pod for point-in-time test"
    exit 1
fi

# Pipe the test script over stdin to a python invocation inside the pod —
# avoids the triple-layer quoting that fails when embedding multi-line code.
raw=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" \
    "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n news exec -i $pod -- env PYTHONPATH=/pkg python3 -" 2>&1 <<'PY'
import asyncio, json
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def call(tool, args):
    async with streamablehttp_client("http://localhost:8080/mcp/") as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            res = await s.call_tool(tool, args)
            # FastMCP routes dict returns to structuredContent and leaves
            # content empty; older clients expect content[0].text. Handle both.
            if getattr(res, "structuredContent", None):
                sc = res.structuredContent
                # FastMCP wraps non-object schemas in {"result": ...}.
                if isinstance(sc, dict) and set(sc.keys()) == {"result"}:
                    return sc["result"]
                return sc
            if res.content:
                return json.loads(res.content[0].text)
            raise RuntimeError(f"empty result for {tool}: {res!r}")

async def main():
    out = {}
    out["briefing_current"] = await call("get_briefing", {"since": "24h", "limit": 1})
    out["briefing_historical"] = await call("get_briefing", {
        "since": "2024-01-01T00:00:00Z",
        "until": "2024-01-31T23:59:59Z",
        "limit": 1,
    })
    out["search_current"] = await call("search_articles", {
        "query": "news", "top_k": 1, "since": "24h",
    })
    out["search_historical"] = await call("search_articles", {
        "query": "news", "top_k": 1,
        "since": "2024-01-01T00:00:00Z",
        "until": "2024-01-31T23:59:59Z",
    })
    print(json.dumps(out))

asyncio.run(main())
PY
)

# Strip any trailing kubectl noise — last newline-separated chunk should be JSON.
json=$(printf '%s\n' "$raw" | awk '/^{/{j=$0} END{print j}')
if ! printf '%s' "$json" | python3 -c 'import sys,json; json.loads(sys.stdin.read())' 2>/dev/null; then
    fail "news: point-in-time MCP call returned non-JSON"
    printf '%s\n' "$raw" >&2
    exit 1
fi

assert_field() {
    local title=$1 key=$2 field=$3 expected=$4
    actual=$(printf '%s' "$json" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())['$key']['$field']
print(d)
")
    if [[ "$actual" != "$expected" ]]; then
        fail "$title: $key.$field=$actual (expected $expected)"
        exit 1
    fi
    pass "$title"
}

assert_keys() {
    local title=$1 key=$2 expected=$3
    actual=$(printf '%s' "$json" | python3 -c "
import sys, json
print(','.join(sorted(json.loads(sys.stdin.read())['$key'].keys())))
")
    if [[ "$actual" != "$expected" ]]; then
        fail "$title: keys=[$actual] (expected [$expected])"
        exit 1
    fi
    pass "$title"
}

ENVELOPE_KEYS="as_of,is_historical,query_window,results"

assert_keys "news: get_briefing returns envelope" briefing_current "$ENVELOPE_KEYS"
assert_field "news: get_briefing 24h window is_historical=false" briefing_current is_historical False
assert_field "news: get_briefing 2024-01 window is_historical=true" briefing_historical is_historical True
assert_keys "news: search_articles returns envelope" search_current "$ENVELOPE_KEYS"
assert_field "news: search_articles 24h window is_historical=false" search_current is_historical False
assert_field "news: search_articles 2024-01 window is_historical=true" search_historical is_historical True
