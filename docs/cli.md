# CLI

tank-claw-os keeps the tank-os host-side command name:
`/usr/local/bin/clawx`.

The command is a compatibility wrapper. It delegates into the running
`clawx` rootless Podman container and executes the pinned `claw-code` binary
inside that container.

For the default instance:

```bash
systemctl --user status clawx.service
clawx --version
clawx prompt "say hello"
```

The wrapper requires provider-neutral runtime config for normal model calls:

```env
AGENT_PROVIDER=ollama
AGENT_BASE_URL=http://ollama.example.internal:11434/v1
AGENT_MODEL=replace-with-ollama-model
```

Config lookup order:

```text
AGENT_* environment
AGENT_CONFIG
/run/agent/config.env
~/.clawx/agent.env
```

The wrapper targets the `clawx` container by default. To target another
container, either use `--container`:

```bash
clawx --container clawx-research --version
```

or set `CLAWX_CONTAINER`:

```bash
export CLAWX_CONTAINER=clawx-research
clawx --version
```

For low-level debugging, use Podman directly:

```bash
podman exec -it clawx sh
podman logs -f clawx
```
