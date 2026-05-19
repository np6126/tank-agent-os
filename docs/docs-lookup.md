# Docs Lookup

tank-agent-os ships an optional documentation-lookup MCP backed by
[`arabold/docs-mcp-server`](https://github.com/arabold/docs-mcp-server)
(v2.3.0). The opencode image auto-enables it; the claw image leaves the
Quadlet disabled because claw-code does not auto-discover MCP endpoints.
The agent stays sandboxed; only the docs-mcp container reaches upstream
documentation hosts, and only through the same egress proxy as everything
else.

## What ships

| Container | Image source | Role |
|---|---|---|
| `docs-mcp` | `ghcr.io/arabold/docs-mcp-server@<digest>` | Indexes and serves developer docs over MCP. Scrapes via headless Chromium (baked into the image); index DB lives in a named podman volume (`docs-mcp-data`). Bound to the `clawx-isolated` bridge; reachable from the agent at `http://docs-mcp:6280/mcp`. |

Whether it auto-starts is controlled at image build:

| `AGENT_KIND` | Quadlet state | Reason |
|---|---|---|
| `opencode` | `[Install] WantedBy=default.target` is appended → auto-enabled on first boot | opencode's MCP config wires `http://docs-mcp:6280/mcp`; the stack must be up for the tool to appear |
| `claw` | no `[Install]` section → not enabled by default | claw-code doesn't auto-discover MCP endpoints; operator wires manually if desired |

Idle resource footprint is the heaviest of the three MCPs we ship — about
600 MB image (Chromium dominates) and 250–400 MB RSS at rest. The index
volume grows with the indexed corpus.

## Activation

For **`AGENT_KIND=opencode`**, only step 1 is required — the container
auto-starts; step 2 and 3 below are already done by the image. For
**`AGENT_KIND=claw`**, all three steps apply.

### 1. Extend the egress proxy allowlist

docs-mcp's scraper reaches whatever upstream documentation site the
operator points it at. Defaults in tank-agent-os assume four sites; add
them to the proxy allowlist (this happens **on the proxy host**, not on
the agent VM):

| Site | Hosts the scraper actually contacts |
|---|---|
| Python stdlib | `docs.python.org` |
| Rust crates / stdlib | `docs.rs` |
| MDN (web platform) | `developer.mozilla.org` |
| Go packages | `pkg.go.dev` |

If your proxy implementation matches by parent domain (the reference
`leash` proxy does), the parent hosts above are sufficient. With a
strict-match proxy you may need to add subdomain entries depending on
which engines the scraper hits (e.g. `static.python.org` for asset
fetches; check the proxy's deny log if a scrape returns empty).

Any site not in the allowlist will simply fail to scrape — same fail-soft
model as SearXNG.

### 2. Sync the proxy drop-in onto docs-mcp

`tank-clawx-secrets` writes
`~/.config/containers/systemd/docs-mcp.container.d/10-secrets.conf` with
`HTTP_PROXY`, `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS` and the merged CA bundle
— same plumbing as the clawx container. docs-mcp's scraper uses Node.js's
HTTPS stack, so `NODE_EXTRA_CA_CERTS` is the trust-anchor knob (mirrors the
agent container).

```bash
tank-clawx-secrets
```

### 3. Enable and start the unit

```bash
systemctl --user enable --now docs-mcp.service
podman ps   # docs-mcp should be Up
```

Verify docs-mcp responds:

```bash
curl -sS http://docs-mcp:6280/mcp -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

(Run from inside the clawx container — `podman exec -it clawx sh` — or from
any process on `clawx-isolated`.)

## What the agent sees

| Agent | Docs-lookup behaviour after activation |
|---|---|
| `opencode` | `gen-opencode-config` wires `http://docs-mcp:6280/mcp` as an MCP endpoint automatically (`mcp.docs-mcp` block in `/etc/clawx/opencode-config.json`). When the container is up, search/scrape tools appear in opencode's tool registry. Indexing happens on demand — the first agent query for a new doc set triggers a scrape, subsequent queries hit the local DB. |
| `claw-code` | The MCP endpoint is not auto-wired. Configure `http://docs-mcp:6280/mcp` as a claw-code MCP server in claw-code's own config (see upstream docs). |

The agent does not reach the doc hosts directly. The scraper that lives
inside docs-mcp does, through the egress proxy, bound by the allowlist.
This is identical to the SearXNG threat-model in `docs/web-search.md`.

## Trust boundary

docs-mcp runs in the **same trust class as searxng** and `mcp-searxng`:
own container, own UID inside the user namespace, own filesystem (named
podman volume for the index DB), no agent API keys in its env.
PostHog telemetry is disabled (`DOCS_MCP_TELEMETRY=false`) at the Quadlet
level; even if that regressed, the egress allowlist does not include
PostHog hosts so the call fails at the proxy. See
[`audits/docs-mcp-server-2026-05-19.md`](../audits/docs-mcp-server-2026-05-19.md)
for the adoption-time audit (disposition: accept with mitigation).

## Disabling

```bash
systemctl --user disable --now docs-mcp.service
```

The agent's MCP tool registry will then show the docs-mcp endpoint as
unreachable — fail-soft, no impact on other tools.

## Updating

Bump `DOCS_MCP_REF` in `bootc/Containerfile` and rebuild. Re-run the
adoption-gate audit if the image upgrade crosses a major version; record
the result in `audits/docs-mcp-server-<ISO-date>.md`. See
[security.md → MCP Adoption Gate](security.md#mcp-adoption-gate) for the
methodology.
