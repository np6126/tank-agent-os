# service-gator audit — 2026-05-19

**Target.** `ghcr.io/lobstertrap/service-gator@sha256:792dd2cc83d94b4748a9b4d216f3f6dd2895d05adc17bf16a4a249e8ce43d232`
**Upstream source.** `github.com/LobsterTrap/service-gator` HEAD `b69814b` (2026-04-15, last commit before image build on 2026-04-16).
**License.** MIT OR Apache-2.0.
**Method.** Code review against the CSA `mcpserver-audit` framework
([ModelContextProtocol-Security/mcpserver-audit](https://github.com/ModelContextProtocol-Security/mcpserver-audit)).
The framework is a guided methodology (prompts + checks), not a CLI tool —
the checks were applied by static scanning of the upstream source tree at
commit `b69814b` (`git clone https://github.com/LobsterTrap/service-gator.git
&& git -C service-gator checkout b69814b`) plus `cargo audit` for dependencies.

## Disposition

**Accept.** Two transitive-dependency advisories are present in the
runtime dependency graph (rustls-webpki, time, quinn-proto, rand); none
are exploitable in service-gator's deployment context inside tank-agent-os
(no QUIC listener, no adversarial date parsing, no global logger override).
The remaining findings are unmaintained-crate notices in `integration-tests`,
which are not shipped in the runtime image. No code-level findings.

## Checks applied

| Check | Result |
|---|---|
| Credential management (CWE-798, CWE-522) | PASS — secrets via env vars, `*_FILE` for container secrets, no hard-coded values. |
| Dynamic content execution (CWE-94, CWE-78) | PASS — all `Command::new(...)` invocations use `.args(&[...])` array form; no shell strings, no string interpolation into argv. |
| Network port binding (CWE-200) | INFO — server binds to operator-provided `--mcp-server <addr>:<port>`; default in our deploy is `0.0.0.0:8080` inside the `clawx-isolated` rootless-podman bridge. No exposure outside the bridge. |
| Authentication / authorization | PASS — optional bearer-token auth (`SERVICE_GATOR_SECRET[_FILE]`) with constant-time comparison via `subtle::ConstantTimeEq`. Scope-restricted by design (entire purpose of the project). |
| Logging of sensitive data (CWE-200, CWE-532) | PASS — token-rejection logs identify reason only ("expired", "invalid signature"), never log token values. |
| Memory safety (unsafe Rust) | PASS — `workspace.lints.rust = { unsafe_code = "deny" }`; no `unsafe` blocks in source. |
| Supply chain — runtime crates | INFO — 5 transitive runtime advisories; see below. |
| Supply chain — dev-only crates | INFO — 1 advisory (`paste` unmaintained) limited to `integration-tests`. |
| Container build (docker-security check) | PASS — multistage build, UBI10-minimal runtime, no SUID/SGID adds, ENTRYPOINT is the binary (no shell wrapper), `--frozen` on `cargo build` (lockfile-enforced). |
| Pinning / supply chain | PASS — image consumed by digest only in `bootc/Containerfile` (`SERVICE_GATOR_REF`); no `:latest`. |

## Detailed findings

### F-SG-001 — `rustls-webpki` advisories (RUSTSEC-2026-0049, 0098, 0099, 0104)

**Severity.** Informational in our context.
**Where.** Transitive via `reqwest → rustls → rustls-webpki`.
**Risk.** Outbound TLS to GitHub/GitLab/Forgejo/JIRA could in theory accept
a malformed CRL or a CA-issued certificate whose name constraints contain
URI/wildcard cases mishandled by the pre-patch parser. Exploiting requires
either a malicious CA in the trust store or a man-in-the-middle with a
crafted certificate.
**Disposition.** **Accept.** service-gator's outbound traffic in
tank-agent-os is mediated by the egress proxy ([leash](docs/security.md)),
which performs its own TLS termination on the operator-managed side.
The trust store inside the service-gator container is the system default
(UBI10) — no operator-injected CAs. Upstream advisory will be cleared when
LobsterTrap bumps `reqwest`.

### F-SG-002 — `quinn-proto` DoS (RUSTSEC-2026-0037)

**Severity.** Informational.
**Where.** Pulled in transitively by `reqwest` for HTTP/3 support.
**Risk.** service-gator does not open a QUIC endpoint; the crate is in the
dependency graph but unreachable code at runtime.
**Disposition.** **Accept.** Not exploitable.

### F-SG-003 — `time` stack exhaustion (RUSTSEC-2026-0009)

**Severity.** Informational.
**Where.** Pulled in via `gouqi` (JIRA client) and other deps.
**Risk.** Adversarially crafted date string parsed via `time::parse_format`
could exhaust the stack.
**Disposition.** **Accept.** Date strings parsed by service-gator originate
from JIRA's own REST API responses — adversarial parsing path requires a
compromised JIRA instance, in which case the agent has already lost the
trust boundary.

### F-SG-004 — `rand` unsoundness (RUSTSEC-2026-0097)

**Severity.** Informational.
**Where.** Transitive via `rmcp` and `reqwest`.
**Risk.** Only manifests when overriding the global logger with one that
uses `rand::rng()` — does not apply to service-gator's `tracing` setup.
**Disposition.** **Accept.** Not reachable.

### F-SG-005 — `paste` unmaintained (RUSTSEC-2024-0436)

**Severity.** None for runtime.
**Where.** `integration-tests` crate only — not in the runtime binary.
**Disposition.** **Accept.** Test-only dependency.

### F-SG-006 — `git config --global safe.directory '*'`

**Severity.** Informational.
**Where.** `src/bin/service_gator.rs:235` (`configure_git_safe_directory`).
**What.** At process start, service-gator runs
`git config --global --add safe.directory '*'` so it can read agent workspaces
mounted as volumes owned by a different UID.
**Risk.** The setting is per-container (each container has its own
`$HOME/.gitconfig`); it does not affect the host. It does mean that any
git command run inside the service-gator container will treat *any* path
as a safe directory.
**Disposition.** **Accept.** Documented in code; bounded by the
container filesystem; no privileged operations occur off the
operator-supplied scopes.

## Recommended ongoing controls

- Track upstream issues for the `rustls-webpki` and `quinn-proto` bumps in
  `reqwest`; revisit disposition when `service-gator` ships a release that
  picks up patched versions.
- Re-run this audit when `SERVICE_GATOR_REF` is bumped in
  `bootc/Containerfile` (the auto-update policy in `docs/security.md` ties
  bump cadence to operator-driven review).

## Raw outputs

`cargo audit` summary (run 2026-05-19, against `Cargo.lock` at HEAD `b69814b`):

```
error: 6 vulnerabilities found!
warning: 3 allowed warnings found
```

Advisory IDs above. To re-derive in machine-readable form: clone
`LobsterTrap/service-gator` at the same commit and run `cargo audit --json`.
