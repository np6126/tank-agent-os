# First Boot

Steps to go from a freshly provisioned tank-agent-os VM to a working agent
session. Complete them in order.

## 1. Verify The VM

SSH in as `clawx` and confirm the user containers are up. `clawx` and
`service-gator` are always running; on an `opencode` or `claude` build
`searxng`, `mcp-searxng`, and `docs-mcp` auto-start too.

```bash
podman ps
cat /etc/clawx/agent.kind    # → `claw`, `opencode`, or `claude`
```

`agent.kind` records which agent variant this image was built with
(`--build-arg AGENT_KIND=…` at image-build time). All three variants are
invoked through the same `clawx` host wrapper.

If `clawx` or `service-gator` is not running:

```bash
systemctl --user start clawx.service service-gator.service
podman logs clawx
podman logs service-gator
```

## 2. Configure The Model Provider

Create `~/.clawx/agent.env` with the provider settings for this instance.
A template is at `/usr/share/tank-os/agent-config.env.example`.

```bash
install -d -m 0700 ~/.clawx
printf '%s\n' \
  'AGENT_PROVIDER=ollama' \
  'AGENT_BASE_URL=http://ollama.example.internal:11434/v1' \
  'AGENT_MODEL=replace-with-model-name' \
  > ~/.clawx/agent.env
```

See [model-providers.md](model-providers.md) for all supported providers and
the matching secret names.

## 3. Store The API Key

`clawx setup` stores the secret, regenerates the secret/env Quadlet drop-ins,
and restarts the agent — one idempotent step. Pipe the value on stdin:

```bash
printf '%s' "$AGENT_API_KEY" | clawx setup agent_api_key
```

Re-run `clawx setup` (no argument) any time you change `agent.env` or add a
secret — see [cli.md](cli.md#applying-configuration).

## 4. Verify The Agent Responds

```bash
clawx --version
```

For a one-shot prompt:

| `AGENT_KIND` | Command |
|---|---|
| `claw`     | `clawx prompt "say hello"` |
| `opencode` | `clawx "say hello"` (wrapper prepends `run` automatically) or `clawx run "say hello"` |
| `claude`   | `clawx "say hello"` (bare prompt → headless `-p`) or `clawx -p "say hello"` |

Bare `clawx` (no args) on an `opencode` or `claude` build opens the interactive
TUI with the configured model pre-selected.

If `--version` prints but the prompt call fails, the model provider is not
reachable. Check `AGENT_BASE_URL` and confirm the provider is accessible from
the VM.

## 5. Configure service-gator (Optional)

service-gator gives the agent scoped access to external services such as
GitHub, GitLab, Forgejo, and JIRA. Skip this step if the agent does not need
those tools.

Store each credential — `clawx setup` applies it in the same step:

```bash
printf '%s' "$GH_TOKEN" | clawx setup gh_token
```

Supported secret names: `gh_token`, `gitlab_token`, `forgejo_token`,
`jira_api_token`.

Configure the scope file to define exactly which repositories and projects the
agent is allowed to interact with. A template with all supported fields is at
`/usr/share/tank-os/scopes.json.example`:

```bash
mkdir -p ~/.config/service-gator
cp /usr/share/tank-os/scopes.json.example ~/.config/service-gator/scopes.json
$EDITOR ~/.config/service-gator/scopes.json
clawx setup        # apply the edited scopes.json
```

service-gator rejects any repository not listed in this file, regardless of
which tokens are configured. See [service-gator.md](service-gator.md) for the
permission reference.

The service-gator MCP endpoint (`http://service-gator:8080` on the
`clawx-isolated` bridge) is wired automatically for all three agent
variants — opencode via `gen-opencode-config`, claw-code via the baked
`/etc/clawx/claw-settings.json`, Claude Code via `/etc/clawx/claude-mcp.json`.
Nothing to configure beyond the secrets.

## 6. Configure The Egress Proxy (Optional)

> **Skip this step** if the instance was provisioned with a cloud-init template
> that includes proxy configuration (`clawx-with-proxy-user-data.yaml`,
> `clawx-leash-user-data.yaml`). Those templates write `/etc/clawx/proxy.env`
> and create the required Podman secrets automatically — the proxy is already
> active.

Only continue here if you are setting up a local dev VM without cloud-init and
want to add proxy support manually. The security model intentionally limits
`clawx` sudo to two commands (`bootc` and `systemctl restart
clawx-nftables.service`); writing `/etc/clawx/proxy.env` falls outside that
scope and needs `wheel` membership (present on dev builds, see
[build.md](build.md)) or a separate root session.

```bash
# Proxy host config for the nftables setup script (requires root). Without
# this file, clawx-nftables.service installs deny-all rules even when a
# proxy_url secret exists.
printf 'CLAWX_PROXY_URL=http://proxy.example.internal:8080\nCLAWX_PROXY_PORT=8080\n' \
  | sudo tee /etc/clawx/proxy.env

printf '%s' 'http://proxy.example.internal:8080' | podman secret create proxy_url -
cat /path/to/mitmproxy-ca-cert.pem | podman secret create proxy_ca_cert -
sudo systemctl restart clawx-nftables.service
clawx setup        # wire the proxy secrets into the container
```

After this step, direct outbound connections from the agent container are
blocked — all external traffic must flow through the proxy.

Restarting `clawx-nftables.service` also installs the proxy CA certificate
into the host system trust store
(`/etc/pki/ca-trust/source/anchors/clawx-proxy-ca.pem`), so host-level
processes — Podman image pulls and `sudo bootc upgrade` — trust the MITM
certificate without any extra steps.

## 7. Web Search (Optional)

On **`opencode`** and **`claude`** the SearXNG + `mcp-searxng` stack is
auto-enabled at image build and wired into the agent config; just make sure the
egress-proxy allowlist contains the engine hosts (default engines: DuckDuckGo,
Wikipedia, StackExchange, MDN).

On **`claw`** the Quadlets ship disabled. To enable: extend the proxy
allowlist, then

```bash
systemctl --user enable --now searxng.service mcp-searxng.service
```

See [web-search.md](web-search.md) for the trust model, the engine list, why
GitHub is intentionally not in the set, and how to disable.

## 8. Docs Lookup (Optional)

Same shape as Web Search. On **`opencode`** and **`claude`**, `docs-mcp` is
auto-enabled and wired into the agent config; extend the egress-proxy allowlist
with the doc hosts you want indexed (defaults: `docs.python.org`, `docs.rs`,
`developer.mozilla.org`, `pkg.go.dev`). On **`claw`** the Quadlet ships
disabled:

```bash
systemctl --user enable --now docs-mcp.service
```

See [docs-lookup.md](docs-lookup.md) for the trust model and how to disable.

## 9. Skills and Memory (Optional)

All three supported agents read skills from a single host-side directory. Drop
a `SKILL.md` folder in and the next agent session sees it:

```bash
mkdir -p ~/.clawx/skills/my-skill
# write ~/.clawx/skills/my-skill/SKILL.md ...
```

See [skills.md](skills.md) for the format.

Persistent agent memory (claw-code's auto-memory and equivalents) is **off by
default** — memory writes go to the container's overlay-FS and are lost on
recreate. To enable across-session memory, rebuild the image with
`--build-arg AGENT_MEMORY_PERSIST=true`. See [memory.md](memory.md) for the
threat-model trade-off and how to wipe memory.

## 10. LLM-Wiki (Optional)

`llm-wiki` gives the agent a persistent, git-backed Markdown knowledge base.
It is opt-in and **always** operator-enabled — never auto-started, even on
`opencode` builds — because it needs git-host setup first.

Outline: create one repo per wiki on your git host and a `wiki-bot-<vm-id>`
service account, set `AGENT_LLM_WIKI_*` in `agent.env`, add the git host to
the egress-proxy allowlist, then store the token and start the service:

```bash
printf '%s' "$LLM_WIKI_TOKEN" | clawx setup llm_wiki_token
systemctl --user start llm-wiki.service
```

The full procedure — the `agent.env` keys, capability tiers, MCP wiring,
and the skill drop-in — is in [llm-wiki.md](llm-wiki.md).

## Verify

Once the agent is configured and running, confirm the whole stack with the
built-in self-test:

```bash
clawx selftest
```

It functionally checks containment (direct egress blocked, egress proxy
reachable), the agent container and binary integrity, the read-only
instruction file, and MCP connectivity. Each check prints `PASS`, `WARN`, or
`FAIL`; the command exits non-zero if anything FAILs.

## Reference

| What changed | What to run |
|---|---|
| Added or rotated a secret | `clawx setup <secret-name>` (value on stdin) |
| Edited `~/.clawx/agent.env` (incl. `AGENT_LLM_WIKI_*`) or `scopes.json` | `clawx setup` |
| Edited `/etc/clawx/proxy.env` | `sudo systemctl restart clawx-nftables.service` |
| Installed a skill in `~/.clawx/skills/` | Start a new agent session — no restart needed |
| Want to wipe persistent agent memory | `rm -rf ~/.clawx/claude-projects/` (only on `AGENT_MEMORY_PERSIST=true` builds) |
| OS update available | `sudo bootc upgrade --apply` |
