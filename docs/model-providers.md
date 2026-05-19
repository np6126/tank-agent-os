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
process. The same `agent.env` file works for both `AGENT_KIND=claw` and
`AGENT_KIND=opencode` — the wrapper translates per-agent CLI conventions
on the host side.

### Model name prefixes

The `local/` prefix in `AGENT_MODEL` is a claw-code convention that signals
"strip this prefix before sending to a non-default base URL" — needed for
Ollama compatibility because Ollama only knows the bare model name. claw-code
does the stripping inside `wire_model_for_base_url()` (via patch
`claw-fix-openai-prefix-strip.patch`).

opencode has no equivalent stripping, but the `clawx` wrapper and the
opencode config generator (`gen-opencode-config`) both strip the `local/`
prefix before talking to opencode, so the same `agent.env` produces
identical behaviour with either agent. You can write
`AGENT_MODEL=local/qwen3.6:27b-ctx32k` and switch `AGENT_KIND` between
`claw` and `opencode` without touching the config.

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

Create secrets after the machine boots, before starting or restarting the agent
service:

```bash
sudo -iu clawx
printf '%s' "$AGENT_API_KEY" | podman secret create agent_api_key -
tank-clawx-secrets
systemctl --user restart clawx.service
```

Supported model secret names:

| Podman secret | Container env |
| --- | --- |
| `agent_api_key` | `AGENT_API_KEY` plus provider-specific env when possible |
| `openai_api_key` | `OPENAI_API_KEY` |
| `anthropic_api_key` | `ANTHROPIC_API_KEY` |
| `openrouter_api_key` | `OPENAI_API_KEY` |
| `model_endpoint_api_key` | `MODEL_ENDPOINT_API_KEY` plus provider-specific env when possible |

`tank-clawx-secrets` writes rootless Quadlet drop-ins under
`~/.config/containers/systemd/clawx.container.d/`. It does not write keys to
`~/.clawx/agent.env`.
