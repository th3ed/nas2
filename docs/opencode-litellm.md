# Connecting opencode to the nas2 LiteLLM proxy

The nas2 LiteLLM proxy is available on the tailnet at `https://litellm.taile9c9c.ts.net`.
It exposes local Ollama models and cloud models (Claude, Gemini, Kimi) behind a single
OpenAI-compatible API, so any OpenAI-compatible client — including opencode — can use all
of them through one endpoint.

## 1. Get your LiteLLM master key

The master key is stored in Bitwarden Secrets Manager. Retrieve it with the Bitwarden CLI:

```bash
bw login
bw get item 53904946-84fc-46dd-858b-b446001ff47a | jq -r '.fields[] | select(.name=="value") | .value'
```

Or look up secret ID `53904946-84fc-46dd-858b-b446001ff47a` in the Bitwarden SM web UI
under organization `c046a20a-413d-4b54-8a56-b1790122c5ef`.

## 2. Configure opencode

Edit (or create) `~/.config/opencode/opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "nas2": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "nas2 LiteLLM",
      "options": {
        "baseURL": "https://litellm.taile9c9c.ts.net/v1",
        "apiKey": "<your-litellm-master-key>"
      },
      "models": {
        "gemini-2.5-flash": { "name": "Gemini 2.5 Flash" },
        "gemini-2.5-pro":   { "name": "Gemini 2.5 Pro" },
        "gemini-2.0-flash": { "name": "Gemini 2.0 Flash" },
        "claude-opus-4.7":  { "name": "Claude Opus 4.7" },
        "claude-sonnet-4.6":{ "name": "Claude Sonnet 4.6" },
        "claude-haiku-4.5": { "name": "Claude Haiku 4.5" },
        "kimi-k2.6":        { "name": "Kimi K2.6" },
        "gemma4:e4b":       { "name": "Gemma 4 E4B (local)" },
        "qwen3-coder-next:latest": { "name": "Qwen3 Coder (local)" },
        "qwen3:4b-instruct-2507-q8_0": { "name": "Qwen3 4B (local)" }
      }
    }
  }
}
```

Replace `<your-litellm-master-key>` with the key from step 1.

## 3. Select a model in opencode

Run opencode, open the model picker, and choose **nas2 LiteLLM** as the provider.
The models listed above will appear.

## Notes

- **You must be on the tailnet** (Tailscale connected) for `litellm.taile9c9c.ts.net` to resolve.
- Cloud models (Claude, Gemini, Kimi) pass through the Presidio PII guardrail — prompts are
  masked before leaving the tailnet and unmasked in the response.
- Local models (Gemma, Qwen3) run entirely on nas2 with no external API calls.
- Gemini free-tier rate limits: `gemini-2.5-flash` 15 RPM / 1M tokens per day;
  `gemini-2.5-pro` 5 RPM.
- To see all available models at runtime:
  ```bash
  curl -s https://litellm.taile9c9c.ts.net/v1/models \
    -H "Authorization: Bearer <master-key>" | jq '[.data[].id]'
  ```
