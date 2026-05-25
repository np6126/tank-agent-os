# Security policy

## Scope

This policy covers the **tank-agent-os** image itself — the bootc OS layer, the
appliance composition (systemd units, Quadlets, cloud-init, nftables baseline),
and the build pipeline in this repository.

Out of scope:

- **Upstream agent runtimes** (`opencode`, `claw-code`, `Claude Code`) — report to
  the respective upstream. tank-agent-os pins releases and verifies them, but
  vulnerabilities inside an agent runtime belong with its maintainers.
- **Upstream platform** (Fedora bootc, Podman, systemd, the Linux kernel,
  nftables) — report to those projects. We track and apply their advisories.
- **The audited egress proxy host** — a separate component with its own
  repository and disclosure policy.
- **An operator's individual deployment choices** (allowlist contents, secrets
  management, Proxmox host hardening) — those are operator responsibilities, not
  defects in this project.

## Reporting

Open a private security advisory via GitHub:
**[github.com/np6126/tank-agent-os/security/advisories/new](https://github.com/np6126/tank-agent-os/security/advisories/new)**

GitHub Security Advisories support attachments and stay private until the
maintainer publishes them. Please prefer this over public issues.

Please include:

- Affected image tag / commit
- Reproduction steps or proof-of-concept
- Impact assessment (what an attacker can do)
- Suggested fix or mitigation if you have one

## Response

This is an independent project with a single maintainer. Expected response
times are *best effort*, not SLA:

- Acknowledgement: within 5 working days
- Triage and severity assessment: within 10 working days
- Fix or mitigation: depending on severity and complexity, no commitment beyond
  "as fast as a single maintainer reasonably can"

For incidents that affect operators in production, the maintainer will
prioritise a documented workaround before a code fix where the workaround
materially reduces exposure.

## Coordinated disclosure

Default disclosure window: **90 days** from acknowledgement, extendable by
mutual agreement. Earlier public disclosure may happen if the issue is already
public elsewhere, exploited in the wild, or the upstream component has already
shipped a fix.

## Out-of-band advisories

Security-relevant changes that don't have a CVE — for example, a tightening of
the default nftables baseline — are announced via GitHub Releases.
