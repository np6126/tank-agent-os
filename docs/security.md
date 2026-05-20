# Security Architecture

## Threat Model

An autonomous AI agent is a different class of workload from a conventional
service. It makes decisions at runtime about which tools to call, which files to
read, and which external services to contact — and those decisions are influenced
by content it processes, not just by the operator who started it.

The threats tank-agent-os is designed to contain fall into two categories:

**Network threats** — an agent with unrestricted outbound access can:

- Call external APIs directly, bypassing the application-level scope enforced
  by service-gator.
- Exfiltrate data by sending it to arbitrary internet hosts.
- Interact with services not explicitly granted to it.

**Prompt injection** — an agent that reads workspace content (code, READMEs,
issue descriptions, fetched web pages) may encounter text crafted to look like
operator instructions. A successful injection can redirect the agent's actions
without the operator's knowledge, potentially combining with network access to
cause exfiltration or unintended writes to external repositories.

The design goal is not to make the agent useless, but to make bad outcomes
technically impossible or severely limited rather than merely against policy.

## Defense Strategy

tank-agent-os addresses these threats through **impact containment**, not
detection. Detection-based approaches — input classifiers, output filters,
pattern-matching guardrails — can be bypassed by semantically novel attacks and
add latency and cost. No detection layer is reliable against a sophisticated
adversary.

Impact containment means that even if the agent is manipulated, what it can
actually do is bounded by the environment it runs in:

- It cannot reach network destinations outside what the proxy permits.
- It cannot call service-gator tools outside what `scopes.json` permits.
- It cannot escalate privileges on the host.
- It cannot modify its own runtime configuration or instruction files.
- Its instruction file explicitly describes what content has authority over it
  and what does not.

Each of these properties is enforced at the OS or container level, not at the
application level. The agent process itself has no way to circumvent them.

## Mechanisms

### Layer 1 — Container Network Isolation

Both the `clawx` and `service-gator` containers are placed on a dedicated
Podman bridge network, `clawx-isolated`. This provides container-to-container
connectivity using container-name DNS (`service-gator:8080`) without publishing
any ports to the host. Outbound internet access flows through the host's
routing and is controlled entirely at the host level by nftables.

`clawx-nftables.service` — a root-owned systemd service that runs before the
user session starts — installs nftables rules on the host OUTPUT chain:

- **Without proxy:** a deny-all baseline for the `clawx` UID is always
  installed, regardless of network configuration.
- **With proxy:** the proxy destination is added to the allow-set; all other
  outbound from the `clawx` UID is rejected.

Every container on this UID (clawx, service-gator, mcp-searxng, searxng,
docs-mcp, llm-wiki) is subject to the same rule. service-gator's outbound
API calls (GitHub/GitLab/Forgejo/JIRA) now flow through the egress proxy
alongside everything else — there is no longer a cgroup-based exemption,
so the proxy log is the single, complete audit trail for the agent VM. The agent process
has no `CAP_NET_ADMIN` and cannot modify routing tables or firewall rules.
The nftables table is owned by root and lives entirely outside the
container's reach.

### Layer 2 — Egress Proxy

All outbound HTTP and HTTPS from the `clawx` container flows through an
explicit HTTP proxy running on a separate host. The proxy enforces two
properties the agent VM alone cannot provide:

- **Allowlist enforcement** — every connection is checked against a permitted
  destination list before the TLS handshake completes. Connections to unlisted
  hosts are rejected before any data is exchanged.
- **Tamper-resistant audit log** — a structured record of every request, allowed
  or blocked, is written to persistent storage outside the agent VM. The log
  survives VM compromise or destruction because it lives on the proxy host.

Any HTTP proxy that supports `HTTP_PROXY` / `HTTPS_PROXY` and can enforce a
destination allowlist satisfies the interface. The proxy is a separate
deployment concern and is not part of this repository.

### Layer 3 — Runtime Configuration Injection

The proxy address, port, and CA certificate are never baked into the bootc
image. They are injected at boot time through:

- `/etc/clawx/proxy.env` — a root-owned file that `clawx-nftables.service`
  reads to know which IP to allow outbound to. Written by cloud-init during
  automated provisioning, or manually by the operator at first boot.
- Podman secrets `proxy_url` and `proxy_ca_cert` — read by `tank-clawx-secrets`
  to generate a Quadlet drop-in that sets `HTTP_PROXY`, `HTTPS_PROXY`, and the
  CA bundle environment variables inside the `clawx` container.

When `clawx-nftables.service` starts or restarts, it also reads the
`proxy_ca_cert` Podman secret (via `runuser -u clawx`) and installs it as a
root CA into the host system trust store
(`/etc/pki/ca-trust/source/anchors/clawx-proxy-ca.pem`), then calls
`update-ca-trust extract`. This ensures host-level processes — Podman image
pulls and `bootc upgrade` — trust the MITM certificate. If the secret is
absent, the anchor file is removed and the trust store is updated accordingly.

This keeps the image stateless and provider-neutral. The same image can be
deployed with or without a proxy, pointed at different proxy hosts, or rotated
to a new CA without rebuilding.

### Layer 4 — Prompt Injection Hardening

#### Instruction file

`/etc/clawx/CLAUDE.md` is a root-owned file shipped in the bootc image. It is
mounted read-only into the `clawx` container at two paths so any supported
agent picks it up under the filename it expects:

```
Volume=/etc/clawx/CLAUDE.md:/home/clawx/CLAUDE.md:ro
Volume=/etc/clawx/CLAUDE.md:/home/clawx/AGENTS.md:ro
```

`claw-code` reads `CLAUDE.md`; `opencode` reads `AGENTS.md`. Both agents
discover the file by traversing upward from the working directory
(`/home/clawx/workspaces`), so it is loaded automatically into the system
prompt on every invocation without any wrapper changes. Because the source
file is root-owned on the host and mounted read-only into the container, the
agent cannot modify its own instruction file no matter which agent is
running.

The file establishes a trust hierarchy: content the agent reads while working
(files, web pages, issue bodies) is data to be processed, not instructions to
follow. If embedded content resembles operator instructions, the agent is
directed to flag the anomaly before acting.

#### Service-gator scopes

service-gator enforces an explicit allowlist defined in
`~clawx/.config/service-gator/scopes.json`. The agent can only call tools that
operate on repositories and projects listed in that file. Any repository not
listed is rejected regardless of which tokens are configured.

This bounds what service-gator can do on behalf of the agent even if the agent
is manipulated: a prompt injection that attempts to push code to an unlisted
repository or read from an unlisted project is blocked at the service-gator
layer, before any API call is made.

A template with all supported fields is at
`/usr/share/tank-os/scopes.json.example`. See
[service-gator.md](service-gator.md) for the permission reference.

#### Memory persistence is opt-in

Some agents (notably claw-code via Claude Code's auto-memory) write
their own notes across sessions. tank-agent-os defaults these writes to
the container's ephemeral overlay-FS so they disappear on every
container recreate — there is no agent-written state that survives
unless the operator explicitly enables it.

Enabling persistence requires a build-time flag
(`--build-arg AGENT_MEMORY_PERSIST=true`). When set, `clawx-init`
symlinks the agent's memory directory into `~/.clawx/` so notes survive.
The two-writable-paths invariant is preserved — memory lives inside the
existing agent-state mount.

The reason persistence is opt-in is the prompt-injection-persistence
surface it opens: a malicious document the agent processes during one
session could leave behind a note designed to influence the next
session. The `CLAUDE.md` instruction file ships a defence-in-depth
disclaimer in every image (regardless of the build flag) telling the
agent to treat any persistent notes as data rather than authoritative
commands. That mitigation reduces the surface but doesn't eliminate it,
which is why the default stays off. See [memory.md](memory.md) for the
threat-model write-up and how to wipe memory.

## Hardened Host Configuration

### Sudoers Policy

The image ships a restricted sudoers entry for the `clawx` user:

```
clawx ALL=(ALL) NOPASSWD: /usr/bin/bootc
clawx ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart clawx-nftables.service
```

The `systemctl` entry is scoped to a single command: restarting
`clawx-nftables.service` after a proxy config change. Sudo matching in this
form checks command plus arguments exactly — `stop`, `disable`, or any other
subcommand is rejected. This prevents the `clawx` host session from disabling
the nftables isolation even if it is somehow coerced.

`bootc` is included under the assumption that `clawx` is the sole operator of
the appliance. If OS updates are managed externally (a separate admin user,
Ansible, CI/CD), remove `bootc` from this entry.

The cloud-init templates do not include a `sudo:` override. The image's
`/etc/sudoers.d/clawx` entry is the sole authority for what `clawx` may run
as root.

### Supply Chain Pinning

The service-gator container image is pinned to a specific digest rather than
`:latest`. service-gator mediates the agent's GitHub/GitLab/Forgejo/JIRA
calls — both its scope enforcement and the credentials it holds make a
compromised upstream image a high-value supply-chain target even though the
egress proxy now constrains where it can connect. Pinning to a digest ensures
that `podman pull` cannot silently replace the image.

The agent binary is pinned at image build time via `AGENT_KIND` and the
matching SHA-256 ARG. There is no runtime pull of the agent binary.

| `AGENT_KIND` | Pinned input            | Verified output                       |
|--------------|-------------------------|---------------------------------------|
| `claw`       | Git commit + 5 patches  | SHA-256 of locally built binary       |
| `opencode`   | Release tag + asset name| SHA-256 of upstream tarball + binary  |

For `AGENT_KIND=opencode` there is one further input to pin:
`@opencode-ai/plugin`, opencode's plugin SDK. opencode tries to
`bun install` it on every startup as a background dependency — left
unhandled, this would reach `registry.npmjs.org` at runtime and pull
arbitrary JS, defeating the binary pin above. We instead download the
tarball at build time into the `clawx-runtime` image with
`OPENCODE_PLUGIN_SHA256` verifying the content, then `clawx-init`
copies the resolved tree into the agent's writable mount on first
container start. opencode's own dirty-check finds the dependency
satisfied locally and skips the network call. See
[build.md](build.md#pinned-components) for `OPENCODE_PLUGIN_VERSION`
and the version-bump procedure.

For `claw`, the build is reproducible (`--remap-path-prefix`,
`-C strip=symbols`); any drift in patches, `Cargo.lock`, or the cargo
dependency graph changes the binary hash and fails the build. A Fedora
`rust` package upgrade also changes the hash — re-recording is the explicit
audit step that acknowledges the toolchain change.

For `opencode`, we trust the upstream maintainer's CI to produce the binary
and only verify the artifact's identity (tarball SHA before extraction,
binary SHA after). Trust surface is identical to `service-gator`: pin the
digest of an externally-built artifact.

The hash file ships at `/usr/local/share/tank-os/agent.sha256` (agent-
agnostic path) and can be re-checked on a live VM with
`sudo sha256sum -c /usr/local/share/tank-os/agent.sha256` to detect in-place
tampering of the binary on the bootc filesystem. See
[build.md](build.md#reproducible-build) for the recording-then-pinning
workflow.

#### MCP Adoption Gate

Pinning protects against tampering of the artifact we already chose to
trust; it does nothing to tell us whether the choice was sound. Any MCP
server added to tank-agent-os runs alongside the agent's tool surface and
inherits the agent's blast radius if compromised, so adoption gets a
review pass first, separately from the version-bump cadence.

The review uses the CSA `mcpserver-audit` framework
([ModelContextProtocol-Security/mcpserver-audit](https://github.com/ModelContextProtocol-Security/mcpserver-audit))
as the checklist. It is a guided methodology — prompts plus a directory
of CWE-aligned checks — not a CLI tool, so the work is a structured
source review of the candidate's repo (credential handling, dynamic
execution, network binding, transport security, logging, supply chain).
The output for each adopted MCP lives at `audits/<mcp-name>-<ISO-date>.md`
with a one-paragraph disposition (`accept` / `accept with mitigation` /
`reject`) on top and the per-check results below. Findings that warrant
operator awareness — but do not block adoption — are captured as
informational entries with the rationale for accepting them.

Audits exist today for:

- [`audits/service-gator-2026-05-19.md`](../audits/service-gator-2026-05-19.md)
- [`audits/mcp-searxng-2026-05-19.md`](../audits/mcp-searxng-2026-05-19.md)
- [`audits/docs-mcp-server-2026-05-19.md`](../audits/docs-mcp-server-2026-05-19.md) (accept with mitigation: `DOCS_MCP_TELEMETRY=false` pinned in the Quadlet env)
- [`audits/llm-wiki-server-2026-05-20.md`](../audits/llm-wiki-server-2026-05-20.md) (accept: first-party server, security-hardened by design)

A PR that adds a new MCP must include a matching `audits/<name>-<date>.md`
file.

#### Sigstore verification — queued behind upstream

Digest pinning catches tampering of the artifact we resolved, but it
trusts the registry to have given us the right artifact in the first
place. Sigstore signatures close that gap: the build that produced
the image also publishes a transparency-log entry the consumer can
re-verify before consumption. Pre-check on 2026-05-19 with cosign
v2.4.1:

```
cosign verify ghcr.io/lobstertrap/service-gator@sha256:792dd2c…
  Error: no signatures found
cosign verify ghcr.io/searxng/searxng@sha256:25ff3c04…
  Error: no signatures found
```

None of the images we depend on (service-gator, SearXNG, docs-mcp-server)
ship a Sigstore signature or a SLSA-provenance attestation at the time of
writing. The verification step is therefore queued behind upstream
enabling signing.
When either upstream begins publishing signatures, a CI step using
`thv verify` (stacklok/toolhive) or `cosign verify` with the matching
identity/issuer regex gets added to `.github/workflows/build.yml` ahead
of the `clawx-runtime` build, fail-closed on mismatch.

Until then, the supply-chain controls in place are:

- SHA-256 digest pin on every consumed image (`SERVICE_GATOR_REF`,
  `SEARXNG_REF`, `DOCS_MCP_REF`).
- `--ignore-scripts` plus integrity-checked tarball download for the
  npm-installed `mcp-searxng@1.0.3` and the `@opencode-ai/plugin`
  pre-bake.
- An [MCP adoption gate](#mcp-adoption-gate) source review before any
  MCP enters the runtime image.

### Agent Auto-Update Policy

`opencode` ships with `autoupdate: true` as its built-in default: on start,
it pings the upstream release endpoint and would download a newer binary
if available. `claw-code` has no documented auto-update behaviour.

Two layers prevent silent agent replacement in tank-agent-os:

1. **Egress allowlist excludes update hosts.** The egress proxy MUST NOT
   list `opencode.ai`, `github.com/anomalyco/opencode/releases`, or related
   CDN hosts. Without an allow entry the update probe fails before the TLS
   handshake — no version check, no download, no telemetry. This is the
   structural defence and applies even when the operator forgets the
   per-agent config.
2. **`autoupdate: false` is pinned into the image.** The bootc image ships
   a root-owned read-only config at `/etc/clawx/opencode-config.json`
   mounted into the container at `/home/clawx/.config/opencode/config.json`.
   The agent reads it on start and respects the disabled flag; the file
   cannot be modified from inside the container. Belt-and-braces alongside
   the proxy allowlist.

If a maintainer needs to update opencode, they bump `OPENCODE_REF` /
`OPENCODE_SHA256` in `bootc/Containerfile` **and** `OPENCODE_PLUGIN_VERSION` /
`OPENCODE_PLUGIN_SHA256` in `bootc/clawx-runtime/Containerfile` (the plugin
SDK version must match the binary version — opencode pins it that way
internally), then rebuild. The same audited path as any other pinned
component.

### Agent-Internal Permission Models

opencode (and to a lesser extent claw-code) ships with its own permission
layer that gates tool calls and filesystem access from inside the agent
process. tank-agent-os intentionally relaxes some of these — specifically
`external_directory: "allow"` in the opencode config — because:

- the agent's internal permission layer is built for sessions where the
  user clicks "approve" interactively. In tank-agent-os flows like
  `clawx mcp list` or agent tool invocations there is no operator at the
  prompt, so the default `"ask"` setting auto-rejects and silently
  breaks features.
- the **OS-level container sandbox** (only `~/.clawx` and `~/workspaces`
  mounted writable, no `CAP_NET_ADMIN`, nftables-confined network,
  service-gator-mediated external calls, root-owned ro instruction
  files) is the load-bearing defense and is **not** weakened by the
  in-process permission relaxation. The agent can read `/etc`, `/usr`,
  etc., which are part of the OS image anyway and contain no secrets.

In other words: tank-agent-os treats the agent's internal ACL as a
session-UX feature, not as a security boundary. The container is the
boundary.

## What The Agent Can And Cannot Do

| Action | Possible |
|---|---|
| Call service-gator (MCP tools) | Yes — via bridge network |
| Call model provider (LLM endpoint) | Yes — if proxy permits it |
| Call GitHub directly (bypassing service-gator) | No — depends on `github.com` NOT being in the proxy allowlist; the SearXNG `github` search engine is disabled by default for the same reason. If you ever add `github.com` to the allowlist, this guarantee no longer holds and the agent has a second, scopes.json-bypassing path. Same reasoning applies to gitlab.com / forgejo hosts / `*.atlassian.net`. |
| Call any host not in the proxy allowlist | No — blocked by proxy before TLS |
| Access a repo not listed in scopes.json | No — rejected by service-gator |
| Modify nftables rules | No — no CAP_NET_ADMIN in container |
| Stop `clawx-nftables.service` | No — sudoers allows only `restart`, not `stop` |
| Modify its own instruction file (`/home/clawx/CLAUDE.md` / `AGENTS.md`) | No — read-only mount, root-owned on host |
| Auto-update itself (opencode `autoupdate`) | No — update host not in proxy allowlist; config also pins `autoupdate: false` |
| Reach external search engines directly | No — even with the opt-in SearXNG stack enabled, the agent talks to `mcp-searxng` on the bridge; only SearXNG itself has egress, and only through the same proxy/allowlist as the agent |
| Reach external documentation hosts directly | No — even with the opt-in docs-mcp stack enabled, the agent talks to `docs-mcp` on the bridge; only docs-mcp's scraper has egress, and only through the same proxy/allowlist as the agent |
| Use the llm-wiki knowledge base | Yes — opt-in, always operator-enabled; the agent talks to `llm-wiki` on the bridge. Only the `llm-wiki` container has egress, to the git host only, through the same proxy/allowlist as the agent. Wiki page content is treated as data, not instructions (see `CLAUDE.md`); the server strips known injection patterns on write. See [docs/llm-wiki.md](../docs/llm-wiki.md). |
| Add or override MCP servers via workspace config | No — both agents load only their baked, root-owned MCP config. opencode's project-config discovery is disabled (`OPENCODE_DISABLE_PROJECT_CONFIG=1`); claw-code is patched to honour only User-scope config (`claw-lock-project-config.patch`). Without this, a settings file (`opencode.json` / `.claw/settings.json`) in the writable `~/workspaces` mount — a cloned repo, or a prompt-injected self-write — could inject a new MCP server or shadow a trusted one such as `service-gator`. The blast radius would still be bounded by the proxy / nftables / `scopes.json` controls, but the baked config is the trust anchor for the MCP set. |
| Modify Quadlet drop-in files | No — those directories are not mounted into the container |
| Write to its own config (`~/.clawx/`) | Yes — required for agent runtime state; opencode's XDG paths are redirected here via `XDG_*_HOME` env vars so the agent stays inside this single writable mount |
| Write to the workspace (`~/workspaces/`) | Yes — this is the intended working area |
| Write outside its mounts | No — container filesystem is isolated |
| Carry notes across sessions (memory) | Default: No — agent memory writes go to the container's ephemeral overlay-FS and are lost on recreate. With `--build-arg AGENT_MEMORY_PERSIST=true` at build, `clawx-init` symlinks the agent's memory directory into `~/.clawx/` so notes survive. Default-off because persistent memory is a prompt-injection-persistence surface — see [docs/memory.md](../docs/memory.md) and the disclaimer in `CLAUDE.md`. |
| Install new skills | Yes — operator drops SKILL.md folders into `~/.clawx/skills/`, surfaced into each agent's lookup path via symlinks set up by `clawx-init`. Skills sit at operator-instruction-level trust (same class as `CLAUDE.md`, not workspace-data); their *blast radius* is still bounded by the proxy / `scopes.json` / two-writable-paths controls. **Open trade-off**: the directory lives inside the writable mount, so a manipulated agent can in principle persist its own SKILL.md — operational mitigation is periodic review. See [docs/skills.md](../docs/skills.md). |

## Isolation Without the Proxy

`clawx-nftables.service` installs a deny-all rule for the `clawx` UID
regardless of whether a proxy is configured. All user-1000 containers
(clawx, service-gator, mcp-searxng, searxng, docs-mcp, llm-wiki) sit on
the `clawx-isolated` bridge network; the nftables rules on the host
OUTPUT chain are what constrains every one of them to the proxy.

With a proxy configured, `clawx-nftables.service` adds the proxy destination
to the allow-set so traffic from any of those containers can reach the
public internet — but only through the proxy. Without a proxy, only the
loopback and established-connection rules are added — all new outbound
connections from the clawx UID are rejected. service-gator gets no special
treatment in either case; its API calls follow the same auditable path as
the agent's.

## Trust Boundaries

![Trust boundaries: the agent VM (config, clawx container, service-gator, opt-in MCP servers, host nftables OUTPUT chain) and the separate proxy-host trust boundary, with all egress forced through the proxy to the public internet](diagrams/trust-boundaries.svg)

The proxy host is the boundary between the agent's network namespace and the
public internet. It should be treated as infrastructure: access to it should be
restricted, its logs should be shipped to a SIEM or object storage, and its
allowlist should be reviewed when the agent's scope changes.
