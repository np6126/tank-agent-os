# tank-agent-os

Fedora bootc image for running `claw-code` on the original tank-os rootless
Podman appliance architecture.

## Acknowledgements

This project stands on the shoulders of two upstream projects:

- **[LobsterTrap/tank-os](https://github.com/LobsterTrap/tank-os)** — the OS architecture this repo is based on: Fedora bootc, rootless Podman Quadlets, cloud-init provisioning, service-gator integration, and the rootless secrets model. tank-agent-os is a direct fork of that foundation.
- **[ultraworkers/claw-code](https://github.com/ultraworkers/claw-code)** — the agentic runtime that replaces openclaw in this fork. Built as a Rust CLI, compiled from a pinned commit into the bootc image.

bootc turns a container image into a bootable, updateable Linux OS image. This
repo keeps the tank-os shape: Fedora, the `clawx` service account, rootless
Podman Quadlets, per-instance SSH provisioning, rootless Podman secrets, and
transactional bootc updates. The agent runtime is a pinned `claw-code` build.

## Architecture

```
             Operator
                │
                │ SSH
                ▼
┌──────────── Agent VM (tank-agent-os) ─────────────────────────┐
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │                  clawx container                     │    │
│  │        claw-code  ·  CLAUDE.md (read-only)           │    │
│  └───────────┬─────────────────┬───────────────────┬────┘    │
│              │ MCP             │ nftables:         │         │
│  ┌───────────▼───────┐         │ proxy only        │         │
│  │   service-gator   │         │                   │         │
│  │   scopes.json     │         │                   │         │
│  └─────────┬─────────┘         │         nftables: │         │
└────────────┼───────────────────┼─────────LAN only──┼─────────┘
             │                   │                   │
             ▼                   ▼                   ▼
     GitHub · GitLab       Egress Proxy        Local provider
     Forgejo · Jira    (allowlist · audit)   Ollama · LM Studio
                                │
                                ▼
                        Cloud provider
                     Anthropic · OpenAI
                        OpenRouter · ...
```

## What This Fork Adds

Beyond the base tank-os architecture, this fork contributes:

**claw-code as the agent runtime** — replaces the original agent with
[claw-code](https://github.com/ultraworkers/claw-code), a Rust CLI built from a
pinned upstream commit directly into the bootc image. No runtime pull of the
agent binary; the exact version is fixed at image build time.

**Egress proxy architecture** — the core security idea of this fork. All
outbound traffic from the agent is forced through an explicit HTTP proxy running
on a separate host. The proxy enforces a destination allowlist (connections to
unlisted hosts are rejected before the TLS handshake) and writes a
tamper-resistant audit log to storage outside the agent VM. The agent VM alone
cannot produce a trusted network audit trail; the separate proxy host is the
trust boundary. A reference implementation is maintained in the companion
[leash](https://github.com/np6126/leash) repository. The interface is any standard `HTTP_PROXY` / `HTTPS_PROXY`
compatible proxy with allowlist enforcement and structured logging.

**OS-level network enforcement** — nftables rules, owned by root and installed
before the user session starts, confine the agent UID to the proxy address only.
The agent has no `CAP_NET_ADMIN` and cannot modify these rules from inside the
container. Without a proxy configured, a deny-all baseline is installed anyway,
ensuring OS-level protection regardless of the container's network setup.

**Prompt injection hardening** — a root-owned instruction file
(`/etc/clawx/CLAUDE.md`) is mounted read-only into the agent container. It is
picked up automatically by claw-code on every invocation and establishes a trust
hierarchy: workspace content the agent reads is data, not commands. The agent
cannot modify this file. This is a defence layer specific to autonomous agents
that does not exist in conventional service deployments.

**Hardened host configuration** — several details tightened beyond the base
fork: the `systemctl` sudo permission is scoped to a single specific command
rather than the full binary; `clawx` is not in the `wheel` group; the
service-gator image is pinned to a digest rather than `:latest` (relevant
because service-gator is the only container in the stack with unrestricted
outbound internet access).

**Documented scopes.json model** — a fully annotated `scopes.json` template
ships in the image and in `examples/service-gator/`. The permission model
(read, push-new-branch, create-draft, require-fork, etc.) is documented with
rationale so operators can configure the minimum necessary access for their
use case.

## Why This Is Useful

tank-agent-os packages the host OS, `claw-code` binary, Quadlet units, CLI shim,
service-gator integration, and upgrade path into one OCI bootc image. The
mutable parts stay outside the image:

- runtime config under `~clawx/.clawx`
- workspaces under `~clawx/workspaces`
- API keys in the `clawx` user's rootless Podman secret store
- SSH access configured per instance

For test and demo images, `clawx` is granted passwordless sudo so local
bring-up and bootc update testing match upstream tank-os. For production, use a
separate administrative user or a tightly scoped sudo policy for OS management
and bootc updates.

## Runtime Config

Provider config is runtime input. Do not bake provider endpoints, model names,
API keys, or private hostnames into the image.

```env
AGENT_PROVIDER=ollama
AGENT_BASE_URL=http://ollama.example.internal:11434/v1
AGENT_MODEL=replace-with-ollama-model
```

Config can come from `AGENT_*` environment variables, `AGENT_CONFIG`,
`/run/agent/config.env`, or `~/.clawx/agent.env`. The image ships a template
at `/usr/share/tank-os/agent-config.env.example`.

The host `clawx` command remains the tank-os compatibility wrapper. It
delegates into the running `clawx` container and maps neutral `AGENT_*`
values to the environment expected by `claw-code`.

## Security

Autonomous AI agents make runtime decisions about which services to contact and
which files to read. Standard container isolation limits what a compromised or
manipulated agent can reach, but it is rarely enough on its own. tank-agent-os
treats agent security as a property of the whole stack, not a single control.

**Network containment** — the agent container runs with no `CAP_NET_ADMIN` on a
dedicated bridge network. OS-level nftables rules (always active, regardless of
proxy configuration) block all outbound traffic from the agent UID except to the
configured egress proxy. Direct calls to GitHub, external APIs, or any host not
on the proxy allowlist are rejected before the TLS handshake completes.

**Scoped external access** — the agent cannot call external services directly.
It uses service-gator as a mediated MCP layer that enforces a per-repository,
per-permission allowlist (`scopes.json`). A compromised agent can only reach
what service-gator's allowlist explicitly permits, regardless of which tokens
are configured.

**Prompt injection hardening** — the agent's instruction file
(`/etc/clawx/CLAUDE.md`) is root-owned and mounted read-only into the
container. It is loaded automatically into the system prompt on every
invocation. The file establishes a trust hierarchy: workspace content the agent
reads is data, not commands — and the agent is directed to flag anomalies before
acting on anything that looks like embedded instructions.

**Hardened host** — `clawx` is not in the `wheel` group. The sudoers entry
allows only `bootc` and `sudo systemctl restart clawx-nftables.service`; no
other subcommand is permitted, preventing the host session from disabling the
nftables isolation. The service-gator image is pinned to a specific digest
rather than `:latest`, because it is the only container in the stack with
unrestricted outbound internet access.

See [docs/security.md](docs/security.md) for the full threat model, all
mechanisms, the capability table, and the trust boundary diagram.

## Start Here

- Build the image: [docs/build.md](docs/build.md)
- Import into Proxmox: [docs/proxmox-import.md](docs/proxmox-import.md)
- Configure login access: [docs/provisioning.md](docs/provisioning.md)
- **Get the agent running after first boot: [docs/first-boot.md](docs/first-boot.md)**
- Use the CLI wrapper: [docs/cli.md](docs/cli.md)
- Configure model provider secrets: [docs/model-providers.md](docs/model-providers.md)
- Configure service-gator: [docs/service-gator.md](docs/service-gator.md)
- Understand the security model: [docs/security.md](docs/security.md)

For bootc concepts and day-2 operations, see the upstream [bootc documentation](https://bootc-dev.github.io/bootc/).
For disk image builds, see the [Podman Desktop BootC extension](https://github.com/podman-desktop/extension-bootc)
and [bootc-image-builder docs](https://osbuild.org/docs/bootc/).

## Agent Prompt

Use this prompt with a coding agent to get oriented and run the local VM flow:

```text
I am working in the tank-agent-os repo. This repo builds a Fedora bootc image that runs claw-code as a rootless Podman Quadlet owned by the `clawx` user. Please help me get a local smoke test running.

Goals:
- Build the bootc image `localhost/tank-agent-os:latest` for arm64 or amd64.
- Build a QCOW2 disk image with the Podman Desktop BootC extension or manual bootc-image-builder flow.
- Start the disk image as a Linux VM.
- SSH in as `clawx`, verify `sudo -n true`, `sudo bootc status`, `systemctl --user status clawx.service`, and `podman ps`.
- Configure model provider values through `AGENT_*`, `AGENT_CONFIG`, `/run/agent/config.env`, or `~/.clawx/agent.env`.
- Configure model and service-gator credentials using rootless Podman secrets as the `clawx` user, then run `tank-clawx-secrets`.

Post-boot operations:
- Use the host `clawx` wrapper for CLI operations: `clawx --version`.
- Check service health: `systemctl --user status clawx.service`, `podman ps`, `podman logs -f clawx`.
- Create model provider secrets: `printf '%s' "$AGENT_API_KEY" | podman secret create agent_api_key -`, then run `tank-clawx-secrets` and restart the service.
- Create service-gator secrets the same way: `printf '%s' "$GH_TOKEN" | podman secret create gh_token -`. Edit scopes at `~/.config/service-gator/scopes.json`. Then `tank-clawx-secrets && systemctl --user restart service-gator.service`.
- For low-level debugging, open a shell inside the container: `podman exec -it clawx sh`.

Constraints:
- Do not bake private keys or API keys into the image.
- Keep mutable state under `~clawx/.clawx` and workspaces under `~clawx/workspaces`.
- Keep rootless Podman for the agent and service-gator services.
- Use `bootc switch --apply <registry-ref>` to test image upgrades after the VM is running.
```
