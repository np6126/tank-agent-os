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

Tank-claw-os addresses these threats through **impact containment**, not
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

The rules use `socket cgroupv2` matching with the full cgroup path of the
`service-gator.service` unit to exempt service-gator's outbound traffic from
the clawx deny rule. Both containers run under the same UID (1000) but in
different systemd service cgroups, so kernel-level cgroup matching correctly
separates their traffic without requiring separate user accounts. The agent
process has no `CAP_NET_ADMIN` and cannot modify routing tables or firewall
rules. The nftables table is owned by root and lives entirely outside the
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
mounted read-only into the `clawx` container at `/home/clawx/CLAUDE.md`:

```
Volume=/etc/clawx/CLAUDE.md:/home/clawx/CLAUDE.md:ro
```

claw-code discovers instruction files by traversing upward from the working
directory (`/home/clawx/workspaces`). This file is therefore loaded
automatically into the system prompt on every invocation, without any wrapper
changes. Because it is root-owned on the host and mounted read-only into the
container, the agent cannot modify its own instruction file.

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
`:latest`. service-gator has unrestricted outbound internet access (it is the
agent's permitted channel to external services), so a compromised upstream image
would be the highest-value supply chain target in this stack. Pinning to a
digest ensures that `podman pull` cannot silently replace the image.

The claw-code binary is compiled from a pinned git commit hash at image build
time. There is no runtime pull of the agent binary.

## What The Agent Can And Cannot Do

| Action | Possible |
|---|---|
| Call service-gator (MCP tools) | Yes — via bridge network |
| Call model provider (LLM endpoint) | Yes — if proxy permits it |
| Call GitHub directly (bypassing service-gator) | No — blocked by nftables and proxy |
| Call any host not in the proxy allowlist | No — blocked by proxy before TLS |
| Access a repo not listed in scopes.json | No — rejected by service-gator |
| Modify nftables rules | No — no CAP_NET_ADMIN in container |
| Stop `clawx-nftables.service` | No — sudoers allows only `restart`, not `stop` |
| Modify its own instruction file (`/home/clawx/CLAUDE.md`) | No — read-only mount, root-owned on host |
| Modify Quadlet drop-in files | No — those directories are not mounted into the container |
| Write to its own config (`~/.clawx/`) | Yes — required for claw-code runtime state |
| Write to the workspace (`~/workspaces/`) | Yes — this is the intended working area |
| Write outside its mounts | No — container filesystem is isolated |

## Isolation Without the Proxy

`clawx-nftables.service` installs a deny-all rule for the `clawx` UID
regardless of whether a proxy is configured. Both containers use the
`clawx-isolated` bridge network; the nftables rules on the host OUTPUT chain
are what separate clawx's outbound traffic from service-gator's.

With a proxy configured, `clawx-nftables.service` adds the proxy destination
to the allow-set so the agent can reach the model provider through the proxy.
Without a proxy, only the loopback and established-connection rules are added —
all new outbound connections from the clawx UID are rejected.

In both cases `service-gator` is exempted from the clawx deny rule via cgroup
matching, so it retains its own outbound internet access through the host.

## Trust Boundaries

```
┌─────────────────── agent VM ───────────────────────┐
│                                                    │
│  /etc/clawx/CLAUDE.md (root-owned, ro)             │
│    └── mounted into clawx container read-only      │
│                                                    │
│  clawx container (no CAP_NET_ADMIN, no sudo)       │
│    │ clawx-isolated bridge                         │
│    ├────────────────► service-gator container      │
│    │                    │ scopes.json allowlist    │
│    │                    │ host routing (nftables   │
│    │                    │ cgroup exempt)           │
│    │                    ▼                          │
│    │                  GitHub, GitLab, JIRA, ...    │
│    │                                               │
│    │ host routing (nftables: proxy only)           │
│    ▼                                               │
└────────────────────────────────────────────────────┘
         │ HTTP_PROXY / HTTPS_PROXY
         ▼
┌──── proxy host (separate trust boundary) ──────────┐
│  egress proxy                                      │
│    allowlist check → block or forward              │
│    audit log (outside agent VM)                    │
└────────────────────────────────────────────────────┘
         │ permitted destinations only
         ▼
       public internet
```

The proxy host is the boundary between the agent's network namespace and the
public internet. It should be treated as infrastructure: access to it should be
restricted, its logs should be shipped to a SIEM or object storage, and its
allowlist should be reviewed when the agent's scope changes.
