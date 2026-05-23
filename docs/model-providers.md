# Model Providers And Secrets

tank-agent-os keeps model provider keys out of the image. Users provide
non-secret runtime settings through neutral `AGENT_*` values and provide keys as
rootless Podman secrets owned by the `clawx` user.

## Runtime Provider Settings

Create `~/.clawx/agent.env`, provide `AGENT_CONFIG`, mount
`/run/agent/config.env`, or set these values in the shell:

```env
AGENT_PROVIDER=ollama
AGENT_BASE_URL=http://ollama.example.internal:11434/v1
AGENT_MODEL=replace-with-ollama-model
```

Supported initial providers:

```text
ollama
lmstudio
openrouter
openai
anthropic
custom-openai-compatible
custom-anthropic-compatible
```

The `clawx` wrapper maps OpenAI-compatible providers to `OPENAI_BASE_URL`
and Anthropic-compatible providers to `ANTHROPIC_BASE_URL` inside the agent
process. The same `agent.env` file works for all three agents (`claw`,
`opencode`, `claude`) — the wrapper translates per-agent CLI conventions
on the host side.

### `AGENT_KIND=claude` — Anthropic protocol only

Claude Code speaks only the Anthropic Messages protocol. On a `claude`
image the `clawx` wrapper accepts `AGENT_PROVIDER=anthropic` or
`custom-anthropic-compatible` and rejects the OpenAI family (`ollama`,
`lmstudio`, `openrouter`, `openai`, `custom-openai-compatible`) with a
non-zero exit before the agent starts. A local Ollama backend is reached
via `custom-anthropic-compatible` instead (see below). `claw` and
`opencode` accept every provider in the list above.

On a `claude` image with `AGENT_PROVIDER=custom-anthropic-compatible` the
wrapper points `ANTHROPIC_BASE_URL` at an in-container proxy,
`anthropic-strip-proxy`, instead of at the backend directly. Claude Code
appends a `?beta=true` query parameter to `/v1/messages`; a native Ollama
backend hangs on it (claude-code issue #51239), so the proxy deletes the
query string before forwarding to `AGENT_BASE_URL`. Its egress honours
`HTTP_PROXY`/`NO_PROXY`, so the forwarded request leaves the sandbox
through the same egress proxy as any other agent connection. With
`AGENT_PROVIDER=anthropic` the real Anthropic API is reached directly.
`agent.env` is unchanged, and `claw`/`opencode` do not use the proxy.

When `AGENT_PROVIDER` is `anthropic` or `custom-anthropic-compatible` and
no Anthropic auth secret is provisioned, the wrapper injects a dummy
`ANTHROPIC_API_KEY` — Claude Code refuses to start without a credential
even against a keyless local backend. A provisioned `anthropic_api_key`,
`claude_code_oauth_token`, or `agent_api_key` secret is used as-is.

The operator must allowlist the Anthropic (or gateway) endpoint on the
egress proxy, the same as for any model host. Claude Code's built-in
`WebSearch` tool is executed server-side by the Anthropic API; behind a
`custom-anthropic-compatible` gateway that does not implement server-side
`web_search` it degrades gracefully and the agent falls back to the
SearXNG MCP, which is auto-enabled on `claude` builds (see
[web-search.md](web-search.md)).

Ollama v0.14.0 and later expose an Anthropic Messages API; a `claude`
image reaches it via `custom-anthropic-compatible`:

```env
AGENT_PROVIDER=custom-anthropic-compatible
AGENT_BASE_URL=http://ollama.example.internal:11434
AGENT_MODEL=local/qwen3.6:27b-ctx32k
```

The base URL is the bare host and port, with no `/v1` suffix — the
Anthropic compatibility layer is rooted there and the client appends
`/v1/messages` itself. A trailing `/v1` produces a `/v1/v1/messages`
request that 404s, which Claude Code surfaces as a `model may not exist`
error.

### Model name prefixes

The `local/` prefix in `AGENT_MODEL` is a claw-code convention that signals
"strip this prefix before sending to a non-default base URL" — needed for
Ollama compatibility because Ollama only knows the bare model name. claw-code
does the stripping inside `wire_model_for_base_url()` (via patch
`claw-fix-openai-prefix-strip.patch`).

Neither `opencode` nor `claude` strips the prefix internally, but the
`clawx` wrapper strips `local/` for both before invoking the agent (and
`gen-opencode-config` does the same when generating the opencode config),
so the same `agent.env` produces identical behaviour for all three agents.
You can write `AGENT_MODEL=local/qwen3.6:27b-ctx32k` and switch `AGENT_KIND`
between `claw`, `opencode`, and `claude` without touching the model name.
The `AGENT_BASE_URL` needs to match the chosen provider family: the
OpenAI-compatibility endpoint (`http://host:11434/v1`) for `claw` and
`opencode`, the Anthropic-compatibility endpoint (`http://host:11434`,
Ollama v0.14.0 or later) for `claude`.

### opencode-specific config (auto-generated)

When `AGENT_KIND=opencode`, a root systemd path-unit
(`clawx-opencode-config.path`) watches `~clawx/.clawx/agent.env`. On every
change it regenerates `/etc/clawx/opencode-config.json` from the current
`AGENT_PROVIDER` / `AGENT_BASE_URL` / `AGENT_MODEL` values and restarts
the agent service. The generated config defines a custom provider with
the hard-coded id `agent`, so the wrapper invokes opencode with
`--model agent/<model>` independent of which family the provider belongs
to. The config is root-owned ro-mounted into the container — the agent
cannot rewrite it.

## Secrets

Store secrets after the machine boots. `clawx setup` stores the value,
regenerates the Quadlet drop-ins, and restarts the agent in one step:

```bash
sudo -iu clawx
printf '%s' "$AGENT_API_KEY" | clawx setup agent_api_key
```

Supported model secret names:

| Podman secret | Container env |
| --- | --- |
| `agent_api_key` | `AGENT_API_KEY` plus provider-specific env when possible |
| `openai_api_key` | `OPENAI_API_KEY` |
| `anthropic_api_key` | `ANTHROPIC_API_KEY` |
| `claude_code_oauth_token` | `CLAUDE_CODE_OAUTH_TOKEN` — Claude Code subscription auth (Pro/Max/Team/Enterprise); alternative to `anthropic_api_key` for `AGENT_KIND=claude` |
| `openrouter_api_key` | `OPENAI_API_KEY` |
| `model_endpoint_api_key` | `MODEL_ENDPOINT_API_KEY` plus provider-specific env when possible |

Under the hood `clawx setup` runs `tank-clawx-secrets`, which writes rootless
Quadlet drop-ins under `~/.config/containers/systemd/clawx.container.d/`. No
key is ever written to `~/.clawx/agent.env`.
