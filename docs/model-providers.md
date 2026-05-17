# Model Providers And Secrets

tank-claw-os keeps model provider keys out of the image. Users provide
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
and Anthropic-compatible providers to `ANTHROPIC_BASE_URL` inside the
`claw-code` process.

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
