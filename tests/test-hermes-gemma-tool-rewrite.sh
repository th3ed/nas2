#!/usr/bin/env bash
# Invariant: LiteLLM's gemma_tool_rewrite pre_call_hook converts a
# role:tool message into context that gemma4:e4b can actually read, so
# the model synthesizes a final answer instead of looping on tool
# calls.
#
# Without the hook, Ollama's compiled gemma renderer drops role:tool
# messages from the prompt — every turn the model re-emits a tool_call
# because it never sees the prior result, exhausting the agent
# iteration budget on tasks like "check the weather". See CLAUDE.md
# "Gemma 4 + Ollama drops role:tool messages" gotcha.
#
# Pass criteria (with the hook installed):
#   - finish_reason == "stop"  (not "tool_calls")
#   - response content is non-empty
#   - prompt_tokens > 120  (proxy for "the role:tool message was
#     rewritten into the prompt"; without the rewrite it sits at ~95
#     for this fixture)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TITLE="hermes/litellm: gemma_tool_rewrite synthesizes from role:tool"

LITELLM_KEY=$(ssh_kubectl "get secret litellm-secrets -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}'" | base64 -d 2>/dev/null) || {
    fail "$TITLE: could not read litellm-secrets"
    exit 1
}

read -r -d '' BODY <<'JSON'
{
  "model": "gemma4:e4b",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant. Use web_search when the user asks for current information."},
    {"role": "user", "content": "What is the weather in zip code 22066 right now?"},
    {"role": "assistant", "content": "", "tool_calls": [{"id": "call_xyz", "type": "function", "function": {"name": "web_search", "arguments": "{\"query\": \"weather 22066\"}"}}]},
    {"role": "tool", "tool_call_id": "call_xyz", "content": "{\"success\": true, \"results\": [{\"title\": \"Weather for Great Falls, VA 22066\", \"url\": \"https://weather.com/\", \"snippet\": \"Currently 72F and sunny in Great Falls, VA (22066). Light winds from the west at 8 mph. Humidity 45%. Forecast: high of 78F today, low of 58F overnight.\"}]}"}
  ],
  "tools": [
    {"type": "function", "function": {"name": "web_search", "description": "Search the web", "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}}
  ],
  "stream": false
}
JSON

resp=$(curl -fsSk --max-time 60 \
    -H "Authorization: Bearer ${LITELLM_KEY}" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    https://litellm.taile9c9c.ts.net/v1/chat/completions 2>&1) || {
    fail "$TITLE: HTTP request failed"
    exit 1
}

finish=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['finish_reason'])" 2>/dev/null) || {
    fail "$TITLE: malformed response (no choices[0].finish_reason)"
    exit 1
}
if [[ "$finish" != "stop" ]]; then
    fail "$TITLE: finish_reason='$finish' (expected 'stop' — hook likely not firing, gemma is re-calling the tool)"
    exit 1
fi

content_len=$(echo "$resp" | python3 -c "import json,sys; print(len((json.load(sys.stdin)['choices'][0]['message'].get('content') or '').strip()))" 2>/dev/null) || {
    fail "$TITLE: could not read content length"
    exit 1
}
if [[ "$content_len" -lt 20 ]]; then
    fail "$TITLE: synthesized content too short ($content_len chars)"
    exit 1
fi

prompt_tokens=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['usage']['prompt_tokens'])" 2>/dev/null) || {
    fail "$TITLE: could not read usage.prompt_tokens"
    exit 1
}
if [[ "$prompt_tokens" -lt 120 ]]; then
    fail "$TITLE: prompt_tokens=$prompt_tokens (expected >120 — role:tool message was dropped, hook likely not firing)"
    exit 1
fi

pass "$TITLE: finish=stop, content=${content_len}c, prompt_tokens=${prompt_tokens}"
