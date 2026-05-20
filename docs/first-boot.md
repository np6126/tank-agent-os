# First Boot

Steps to go from a freshly provisioned tank-agent-os VM to a working agent
session. Complete them in order.

## 1. Verify The VM

SSH in as `clawx` and confirm the user containers are up. `clawx` and
`service-gator` are always running; on an `opencode` build `searxng`,
`mcp-searxng`, and `docs-mcp` auto-start too.

```bash
podman ps
cat /etc/clawx/agent.kind    # → `claw` or `opencode`
```

`agent.kind` records which agent variant this image was built with
(`--build-arg AGENT_KIND=…` at image-build time). Both variants are invoked
through the same `clawx` host wrapper.

Both containers should be running. If they are not:

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

## 3. Create The API Key Secret

```bash
printf '%s' "$AGENT_API_KEY" | podman secret create agent_api_key -
```

## 4. Wire The Secrets Into The Container

```bash
tank-clawx-secrets
systemctl --user restart clawx.service
```

`tank-clawx-secrets` writes a Quadlet drop-in under
`~/.config/containers/systemd/clawx.container.d/` that mounts the secrets and
sets the provider-specific environment variables. It must be re-run whenever
secrets are added or removed.

## 5. Verify The Agent Responds

```bash
clawx --version
```

For a one-shot prompt:

| `AGENT_KIND` | Command |
|---|---|
| `claw`     | `clawx prompt "say hello"` |
| `opencode` | `clawx "say hello"` (wrapper prepends `run` automatically) or `clawx run "say hello"` |

Bare `clawx` (no args) on an opencode build opens the interactive TUI with the
configured model pre-selected.

If `--version` prints but the prompt call fails, the model provider is not
reachable. Check `AGENT_BASE_URL` and confirm the provider is accessible from
the VM.

## 6. Configure service-gator (Optional)

service-gator gives the agent scoped access to external services such as
GitHub, GitLab, Forgejo, and JIRA. Skip this step if the agent does not need
those tools.

Create the credentials as Podman secrets:

```bash
printf '%s' "$GH_TOKEN" | podman secret create gh_token -
```

Supported secret names: `gh_token`, `gitlab_token`, `forgejo_token`,
`jira_api_token`.

Run `tank-clawx-secrets` again after creating any service-gator secret, then
restart the service:

```bash
tank-clawx-secrets
systemctl --user restart service-gator.service
```

Configure the scope file to define exactly which repositories and projects the
agent is allowed to interact with. A template with all supported fields is at
`/usr/share/tank-os/scopes.json.example`:

```bash
mkdir -p ~/.config/service-gator
cp /usr/share/tank-os/scopes.json.example ~/.config/service-gator/scopes.json
$EDITOR ~/.config/service-gator/scopes.json
```

service-gator rejects any repository not listed in this file, regardless of
which tokens are configured. See [service-gator.md](service-gator.md) for the
permission reference.

### Pointing claw-code at service-gator

service-gator listens on the `clawx-isolated` bridge network. Inside the
`clawx` container, it is reachable by container name:

```
http://service-gator:8080
```

This MCP endpoint is wired automatically for both agent variants — you
don't need to do anything beyond creating the secrets:

- **`opencode`** — `gen-opencode-config` writes a `mcp.service-gator`
  entry into the generated `/etc/clawx/opencode-config.json`.
- **`claw-code`** — the image ships `/etc/clawx/claw-settings.json`,
  mounted read-only at `~/.claw/settings.json`, with `service-gator`
  in its `mcpServers` block.

## 7. Configure The Egress Proxy (Optional)

> **Skip this step** if the instance was provisioned with a cloud-init template
> that includes proxy configuration (`clawx-with-proxy-user-data.yaml`,
> `clawx-leash-user-data.yaml`). Those templates write `/etc/clawx/proxy.env`
> and create the required Podman secrets automatically — the proxy is already
> active.

Only continue here if you are setting up a local dev VM without cloud-init and
want to add proxy support manually. Note that the security model intentionally
limits `clawx` sudo to two specific commands (`bootc` and
`systemctl restart clawx-nftables.service`); writing `/etc/clawx/proxy.env`
falls outside that scope and requires either `wheel` group membership (present
on dev builds, see [build.md](build.md)) or a separate root session.

```bash
# Write the proxy host config for the nftables setup script (requires root).
# Without this file, clawx-nftables.service installs deny-all rules even when
# a proxy_url secret exists.
printf 'CLAWX_PROXY_URL=http://proxy.example.internal:8080\nCLAWX_PROXY_PORT=8080\n' \
  | sudo tee /etc/clawx/proxy.env

printf '%s' 'http://proxy.example.internal:8080' \
  | podman secret create proxy_url -
cat /path/to/mitmproxy-ca-cert.pem | podman secret create proxy_ca_cert -
tank-clawx-secrets
sudo systemctl restart clawx-nftables.service
systemctl --user restart clawx.service
```

After this step, direct outbound connections from the agent container are
blocked. All external traffic must flow through the proxy.

Restarting `clawx-nftables.service` also installs the proxy CA certificate
into the host system trust store
(`/etc/pki/ca-trust/source/anchors/clawx-proxy-ca.pem`). This ensures
host-level processes — Podman image pulls and `sudo bootc upgrade` — trust
the MITM certificate without any extra steps.

## 8. Web Search

For **`AGENT_KIND=opencode`**: the SearXNG + `mcp-searxng` stack is
auto-enabled at image build, the MCP endpoint is wired in the opencode
config, and `tank-clawx-secrets` writes the proxy drop-in for SearXNG
when you run it. You only need to make sure the egress-proxy allowlist
contains the engine hosts (default-enabled engines: DuckDuckGo,
Wikipedia, StackExchange, MDN).

For **`AGENT_KIND=claw`**: the Quadlets ship but are not enabled. If
you want web search, extend the proxy allowlist, run
`tank-clawx-secrets`, then:

```bash
systemctl --user enable --now searxng.service mcp-searxng.service
```

For both: see [web-search.md](web-search.md) for the trust model, the
engines list, why GitHub is intentionally not in the set, and how to
disable.

## 9. Docs Lookup

Same shape as Web Search. For **`AGENT_KIND=opencode`**, `docs-mcp` is
auto-enabled and the MCP endpoint is wired into the opencode config.
Extend the egress-proxy allowlist with the doc hosts you want indexed
(defaults: `docs.python.org`, `docs.rs`, `developer.mozilla.org`,
`pkg.go.dev`). For **`AGENT_KIND=claw`**, the Quadlet ships disabled:

```bash
systemctl --user enable --now docs-mcp.service
```

See [docs-lookup.md](docs-lookup.md) for the trust model and how to
disable.

## 10. Skills and Memory (Optional)

Both supported agents read skills from a single host-side directory.
Drop a `SKILL.md` folder in and the next agent session sees it:

```bash
mkdir -p ~/.clawx/skills/my-skill
# write ~/.clawx/skills/my-skill/SKILL.md ...
```

See [skills.md](skills.md) for the format.

Persistent agent memory (claw-code's auto-memory and equivalents) is
**off by default** — memory writes go to the container's overlay-FS and
are lost on recreate. To enable across-session memory, rebuild the
image with `--build-arg AGENT_MEMORY_PERSIST=true`. See
[memory.md](memory.md) for the threat-model trade-off and how to wipe
memory if needed.

## 11. LLM-Wiki (Optional)

`llm-wiki` gives the agent a persistent, git-backed Markdown knowledge
base. It is opt-in and **always** operator-enabled — never auto-started,
even on `opencode` builds — because it needs git-host setup first.

Outline: create one repo per wiki on your git host and a
`wiki-bot-<vm-id>` service account, set `AGENT_LLM_WIKI_*` in
`agent.env`, create the `llm_wiki_token` secret, add the git host to
the egress-proxy allowlist, then:

```bash
tank-clawx-secrets
systemctl --user start llm-wiki.service
```

The full procedure — repo layout, service-account permissions,
capability tiers, and the skill drop-in — is in
[llm-wiki.md](llm-wiki.md).

## Verify

Once the agent is configured and running, confirm the whole stack with
the built-in self-test:

```bash
clawx doctor
```

It functionally checks containment (direct egress blocked, egress proxy
reachable), the agent container and binary integrity, the read-only
instruction file, and MCP connectivity. Each check prints `PASS`, `WARN`,
or `FAIL`; the command exits non-zero if anything FAILs.

## Reference

| What changed | What to run |
|---|---|
| Added or removed a secret | `tank-clawx-secrets` then restart the affected service |
| Edited `~/.clawx/agent.env` | `systemctl --user restart clawx.service` |
| Edited `~/.config/service-gator/scopes.json` | `systemctl --user restart service-gator.service` |
| Edited `/etc/clawx/proxy.env` | `sudo systemctl restart clawx-nftables.service` |
| Installed a skill in `~/.clawx/skills/` | Start a new agent session — no service restart needed |
| Edited `AGENT_LLM_WIKI_*` in `~/.clawx/agent.env` | `tank-clawx-secrets` then `systemctl --user restart llm-wiki.service` |
| Want to wipe persistent agent memory | `rm -rf ~/.clawx/claude-projects/` (only present on `AGENT_MEMORY_PERSIST=true` builds) |
| OS update available | `sudo bootc upgrade --apply` |
