# CLI

tank-agent-os keeps the tank-os host-side command name:
`/usr/local/bin/clawx`.

The command is a compatibility wrapper. It delegates into the running
`clawx` rootless Podman container and executes the pinned agent binary at
`/usr/local/bin/agent`. Which agent is behind that path depends on
`AGENT_KIND` at image build time; the wrapper reads `/etc/clawx/agent.kind`
and adjusts the CLI shape accordingly.

For the default instance:

```bash
systemctl --user status clawx.service
clawx --version
```

**Agent-specific invocation:**

| `AGENT_KIND` | Example one-shot prompt                          |
|--------------|--------------------------------------------------|
| `claw`       | `clawx prompt "say hello"`                       |
| `opencode`   | `clawx run "say hello"` (or just `clawx "say hello"`; the wrapper prepends `run`) |

The wrapper also rewrites `--model X` so each agent sees its expected
format: `claw-code` gets the plain model name; `opencode` gets
`${AGENT_PROVIDER}/${AGENT_MODEL}`.

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

## Self-test

`clawx doctor` runs a containment self-test. With functional probes — not
rule inspection — it checks that the VM's isolation is in force and the
runtime is healthy: runtime config, the agent container, agent-binary
integrity, that direct (non-proxy) egress is blocked, that the egress
proxy reaches the model host, the read-only instruction file, MCP
connectivity, and the sidecar containers.

```bash
clawx doctor
```

Sample output from a healthy opencode VM:

```text
clawx doctor — tank-agent-os containment self-test
container: clawx   agent: opencode

  PASS  runtime config: AGENT_PROVIDER / BASE_URL / MODEL set in agent.env
  PASS  clawx container 'clawx' is running
  PASS  agent binary matches the build-recorded SHA-256
  PASS  nftables: direct non-proxy egress from the container is blocked
  PASS  egress proxy reaches the allowlisted model host (HTTP 200)
  PASS  instruction file: CLAUDE.md + AGENTS.md present and read-only
  PASS  MCP servers: 'agent mcp list' reports no failures
  PASS  service-gator container is running

summary: 8 pass, 0 warn, 0 fail
```

Each check prints `PASS`, `WARN`, or `FAIL`; the command exits non-zero
if anything FAILs, so it is usable in scripts and post-deploy gates. It
runs even when the agent container is stopped — diagnosing that is one
of its jobs.

For low-level debugging, use Podman directly:

```bash
podman exec -it clawx sh
podman logs -f clawx
```
