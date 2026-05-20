# Web Search

tank-agent-os ships a self-hosted web-search stack. The opencode image
auto-enables it so the agent gets a search tool out of the box; the claw
image leaves the Quadlets disabled by default (the operator enables them
if wanted). Both agents are wired to discover the MCP endpoint — opencode
via `opencode-config.json`, claw-code via `claw-settings.json` — so on a
claw build the search tool appears as soon as the stack is enabled. The
agent stays sandboxed from the public internet; only the SearXNG
container reaches upstream search engines, and only through the same
egress proxy as the agent itself.

## What ships

| Container | Image source | Role |
|---|---|---|
| `searxng` | `ghcr.io/searxng/searxng@<digest>` | Self-hosted SearXNG. Upstream-engine traffic is routed through the egress proxy via `outgoing.proxies` in `/etc/clawx/searxng-settings.yml` (SearXNG ignores `HTTP_PROXY` env vars for engine calls). The settings file is generated at boot by `gen-searxng-settings` from `searxng-settings.yml.template`, substituting `CLAWX_PROXY_URL` from `/etc/clawx/proxy.env`. |
| `mcp-searxng` | `clawx-runtime` image (npm-installed `mcp-searxng@1.0.3` with `--ignore-scripts`) | MCP server that exposes SearXNG to the agent. Reuses the clawx-runtime image rather than pulling a separate one — avoids Docker-Hub-CDN dependency and keeps the trust class isolated (own container, no agent env/secrets/mounts). Sits on `clawx-isolated`, talks to `searxng:8080` by container name. Zero direct egress. |

Whether they auto-start is controlled at image build:

| `AGENT_KIND` | Quadlet state | Reason |
|---|---|---|
| `opencode` | `[Install] WantedBy=default.target` is appended → auto-enabled on first boot | opencode's MCP config wires `http://mcp-searxng:3000/mcp`; the stack must be up for the tool to appear |
| `claw` | no `[Install]` section → not enabled by default | the claw image keeps the minimal default; the MCP endpoint is still wired (`claw-settings.json`), so enabling the stack is all that is needed |

On an `opencode` build the two containers stay resident even when the
agent never invokes web-search — roughly 150–250 MB combined RSS for
SearXNG (Python/Flask) + `mcp-searxng` (Node MCP shim). Acceptable for
"works out of the box" but worth knowing on resource-constrained hosts.
To free the memory, `systemctl --user disable --now searxng.service
mcp-searxng.service` on the running VM.

## Activation

For **`AGENT_KIND=opencode`**, only step 1 is required — the containers
auto-start; steps 2 and 3 below are already done by the image. For
**`AGENT_KIND=claw`**, all three steps apply.

### 1. Extend the egress proxy allowlist

SearXNG fans out queries to multiple engines. Add the engines you want enabled
in `searxng-settings.yml` to the proxy allowlist (this happens **on the proxy
host**, not on the agent VM). Default engine set in this repo:

| Engine | Hosts the engine actually contacts |
|---|---|
| DuckDuckGo | `html.duckduckgo.com` |
| Wikipedia | `en.wikipedia.org` |
| StackExchange | `api.stackexchange.com` |
| MDN | `developer.mozilla.org` |

If your proxy implementation matches by parent domain (the reference
`leash` proxy does — a `duckduckgo.com` entry also covers
`html.duckduckgo.com`, etc.), you can list the parent host instead of
the specific subdomain. With a strict-match proxy you need the exact
subdomain.

Google, Bing, and **GitHub** are disabled by default in
`searxng-settings.yml`. GitHub is intentionally off because direct GitHub
search would require putting `github.com` in the proxy allowlist — which
would let the agent reach GitHub directly and bypass `scopes.json`.
service-gator is the scoped, audited path for any GitHub interaction. If
you actively want freeform GitHub search through SearXNG and accept the
threat-model change (the "Call GitHub directly: No" row in
`docs/security.md` no longer holds), enable the engine, add
`github.com` + `api.github.com` to the allowlist, and update the docs
to reflect the new posture. Same reasoning applies to GitLab, Forgejo,
and JIRA — any service-gator-covered provider should not be allowed
through the proxy as a separate path.

### 2. Sync the proxy drop-in onto SearXNG

`tank-clawx-secrets` writes
`~/.config/containers/systemd/searxng.container.d/10-secrets.conf` with
`HTTP_PROXY`, `HTTPS_PROXY`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` and the
merged CA bundle volume mount — same plumbing as the clawx container.
SearXNG ignores these env vars for **upstream-engine** traffic (that
path is wired explicitly in `settings.yml`), but they are still needed
for non-engine HTTPS (image proxy, metrics, etc.) to trust the MITM CA.

```bash
tank-clawx-secrets
```

### 3. Enable and start the units

```bash
systemctl --user enable --now searxng.service mcp-searxng.service
podman ps   # both should be Up
```

Verify SearXNG responds:

```bash
curl -s 'http://searxng:8080/search?q=hello&format=json' \
  | jq '.results[0:3] | .[] | .url'
```

(Run from inside the clawx container — `podman exec -it clawx sh` — or from
any process on `clawx-isolated`.)

## What the agent sees

| Agent | Web-search behaviour after activation |
|---|---|
| `opencode` | `gen-opencode-config` wires `http://mcp-searxng:3000` as an MCP endpoint automatically (`mcp.searxng` block in `/etc/clawx/opencode-config.json`). When the containers are up, the search tool appears in opencode's tool registry. opencode's built-in `websearch` (Exa AI) stays inactive because its host is not in the allowlist; mcp-searxng is the working path. opencode's `webfetch` will only succeed for hosts already in the proxy allowlist. |
| `claw-code` | Auto-wired. The image ships `/etc/clawx/claw-settings.json` (mounted read-only at `~/.claw/settings.json`) with `searxng` in its `mcpServers` block; claw-code discovers it on start. claw-code's MCP client is stdio-only and bridges this HTTP endpoint through `mcp-proxy` — while the stack is disabled the endpoint is unreachable and `mcp-proxy` logs a harmless connection error (`Name or service not known`) on each run; enabling the stack clears it. claw-code also has its own built-in `webfetch` that goes through the egress proxy and is limited to allowlist hosts. |

For indexed developer documentation (Python stdlib, Rust crates, Go
packages, MDN by default), prefer the dedicated docs MCP — see
[docs-lookup.md](docs-lookup.md). For freeform web search, SearXNG is
the right path; clicking through to an arbitrary URL is **not**
automatically possible — only allowlisted hosts fetch. See
[security.md](security.md) for the reasoning.

## Trust boundary

SearXNG runs in the **same trust class as clawx** — same UID, same nftables
treatment, same egress proxy, same allowlist enforcement. The only thing the
opt-in stack adds is one more service that the proxy audits and that needs
allowlist entries for its outgoing engine calls. No container on the agent
VM has unrestricted outbound: clawx, service-gator, searxng, and docs-mcp
all route through the same proxy.

## Disabling

```bash
systemctl --user disable --now searxng.service mcp-searxng.service
```

The agent's MCP tool registry will then show the SearXNG endpoint as
unreachable — fail-soft, no impact on other tools.

## Updating

Bump `SEARXNG_REF` in `bootc/Containerfile` (SearXNG image digest) or
`MCP_SEARXNG_VERSION` in `bootc/clawx-runtime/Containerfile` (npm
version pin for `mcp-searxng`) and rebuild. SearXNG follows the
digest-pinning pattern of `service-gator`; `mcp-searxng` is pinned to
an exact npm version and installed with `--ignore-scripts` inside the
`clawx-runtime` image (no separate OCI image to mirror).
