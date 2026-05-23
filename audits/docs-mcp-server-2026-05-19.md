# docs-mcp-server audit — 2026-05-19

**Target.** `ghcr.io/arabold/docs-mcp-server@sha256:a00a30040bac410678c175dcf8b60f5fed6357cf761bcc5a63ab56383ae3e8a9`
(tag `2.3.0`, built 2026-05-17).
**Upstream source.** `github.com/arabold/docs-mcp-server` tag `v2.3.0`.
**License.** MIT.
**Method.** Code review against the CSA `mcpserver-audit` framework
([ModelContextProtocol-Security/mcpserver-audit](https://github.com/ModelContextProtocol-Security/mcpserver-audit)).
The framework is a guided methodology (prompts + checks), not a CLI tool —
the checks were applied by static scanning of the upstream source tree at
tag `v2.3.0` (`git clone --branch v2.3.0 https://github.com/arabold/docs-mcp-server.git`)
plus `npm audit --omit=dev` for runtime dependencies.

## Disposition

**Accept with mitigation.** The runtime dependency tree is clean
(`npm audit --omit=dev` → 0). The upstream Dockerfile correctly bakes
Chromium and sets `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, so the
runtime-install path that would otherwise call out to npm/Playwright
servers is blocked. Two adoption-time mitigations are required:

- **Disable telemetry explicitly** — the project ships PostHog analytics
  on by default, reaching `https://app.posthog.com` on each event. Set
  `DOCS_MCP_TELEMETRY=false` in the Quadlet env.
- **No agent secrets in env** — docs-mcp-server consumes embedding API
  keys (`OPENAI_API_KEY`, `GOOGLE_API_KEY`, etc.) by env var. We
  deliberately leave those unset; the container runs in indexing mode
  with no embedding provider, so the search side falls back to local
  ranking. If a future operator wires an API key in, it must enter via
  podman `--secret`, not bare env, and the agent's own container must
  not inherit the value.

With those two settings applied, no code-level findings remain that
block adoption.

## Checks applied

| Check | Result |
|---|---|
| Credential management (CWE-798, CWE-522) | PASS — API keys read from env; no hard-coded secrets in `src/`. Standard `.env.example` documents the providers. |
| Dynamic content execution (CWE-94) | INFO — uses `vm.runInContext` for scraper sandbox (`src/scraper/utils/sandbox.ts`, `runScripts: outside-only`) and Playwright `frame.$eval` for DOM inspection. Both are constrained executors operating on remote HTML pulled via Playwright; the input is not under our agent's control. |
| Runtime browser install (CWE-829) | PASS — `ensurePlaywrightBrowsersInstalled` short-circuits when `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` or `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` resolves. The upstream production Dockerfile sets both; consuming the published image avoids the otherwise-present `execSync("npm exec -y playwright install …")` path. |
| Telemetry / outbound analytics (CWE-200) | MITIGATED — PostHog telemetry defaults to **enabled** with endpoint `https://app.posthog.com` (`src/telemetry/postHogClient.ts`). Disabled by `DOCS_MCP_TELEMETRY=false` (`src/utils/config.ts:385`) or `--no-telemetry` CLI flag. We set the env var in the Quadlet. As a defence-in-depth, our egress proxy allowlist does not include PostHog hosts, so an event would fail at the proxy even if the kill-switch regressed. |
| Network port binding (CWE-200) | INFO — `src/app/AppServer.ts` and `src/web/web.ts` bind to `host: "0.0.0.0"` by default on port 6280. In our deploy the container exposes only on the `clawx-isolated` rootless-podman bridge; no `PublishPort`. |
| Authentication / authorization | INFO — OAuth2/OIDC bearer-token auth is opt-in via `AuthConfig.enabled`; default OFF. We keep it OFF and rely on bridge isolation (same posture as searxng + mcp-searxng). |
| Writable paths in container | PASS — image uses a named podman volume at `/data` for index storage and `/config` for runtime config, owned by the upstream `node` user (uid 1000). Stays inside the docs-mcp container's own filesystem; does not require any additional volume mount on the clawx container (preserves the two-writable-paths invariant). |
| Logging of sensitive data | PASS — no observed logging of API keys, embedding inputs, or auth tokens. |
| Supply chain — runtime deps | PASS — `npm audit --omit=dev` against `package-lock.json` at `v2.3.0` reports 0 vulnerabilities. |
| Pinning / supply chain | PASS — image consumed by digest pin (`DOCS_MCP_REF=sha256:a00a30040bac…`) in `bootc/Containerfile`. |
| Container base | INFO — `node:22-trixie-slim` (Debian 13 testing); Chromium via apt; runtime user `node` (uid 1000). Larger trust surface than UBI10-minimal, but mirrored across all three SearXNG/MCP containers we ship, and bounded by the bridge. |

## Detailed findings

### F-DM-001 — Telemetry defaults to enabled

**Severity.** Mitigated — informational with required Quadlet setting.
**Where.** `src/telemetry/TelemetryConfig.ts` (`enabled: boolean = true`),
`src/telemetry/postHogClient.ts` (`host: "https://app.posthog.com"`),
`src/utils/config.ts:385` (env hook: `DOCS_MCP_TELEMETRY`).
**Risk.** Without intervention, the container would attempt to POST
events to `app.posthog.com` on startup and on tool calls. Even if
blocked at the egress proxy (PostHog is not in the allowlist), the
inflight failed connection burns operator log lines and leaks the
fact that the container is running.
**Mitigation.** Quadlet sets `Environment=DOCS_MCP_TELEMETRY=false`,
which routes through the kill-switch before any network call.

### F-DM-002 — Sandbox executes remote-fetched JS

**Severity.** Informational.
**Where.** `src/scraper/utils/sandbox.ts` (`vm.runInContext` with
`runScripts: "outside-only"`).
**Risk.** docs-mcp-server scrapes documentation pages and runs their
inline `<script>` content inside a Node `vm` sandbox. The sandbox is
the standard Node escape-prone primitive — known-bypassable in the
general case — but the JS being executed comes from operator-trusted
documentation sites (the four pre-allowlisted hosts:
`docs.python.org`, `docs.rs`, `developer.mozilla.org`, `pkg.go.dev`).
**Disposition.** **Accept.** The threat model assumes the scrape
targets are not actively adversarial; if they become adversarial we
have bigger problems than vm-escape. The sandbox's other purpose —
preventing the scraped JS from doing IO at scrape time — is the
desirable property and it does hold for non-malicious input.

### F-DM-003 — Production Dockerfile passes `POSTHOG_API_KEY` as build ARG

**Severity.** Informational.
**Where.** Upstream `Dockerfile` lines 17-19.
**Risk.** The published image at `ghcr.io/arabold/docs-mcp-server` may
ship with the upstream-author's PostHog API key embedded in the bundle.
**Disposition.** **Accept.** With telemetry disabled at runtime
(F-DM-001 mitigation), the key is never used. If the operator wants
defence in depth, they can rebuild the image without
`POSTHOG_API_KEY` set — but that makes the image an operator self-build
rather than a digest pin — an OSS-release blocker — so not recommended
unless telemetry-disable is felt insufficient.

## Recommended ongoing controls

- Re-run `npm audit --omit=dev` against `package-lock.json` of any new
  tag before bumping `DOCS_MCP_REF`.
- Confirm `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` and
  `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` remain set in the upstream
  production stage when the image is updated — they are the load-bearing
  protection against runtime npm/Playwright fetches.
- Watch upstream for the `DOCS_MCP_TELEMETRY` env var to remain the
  documented kill-switch; if upstream renames or removes it, a future
  bump requires updating the Quadlet.

## Raw outputs

`npm audit --omit=dev` against `docs-mcp-server@v2.3.0` (run 2026-05-19):

```
found 0 vulnerabilities
```
