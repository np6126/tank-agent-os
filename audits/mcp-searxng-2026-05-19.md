# mcp-searxng audit — 2026-05-19

**Target.** `mcp-searxng@1.0.3` from npm
([`sha512-lX7YeZy…`](https://registry.npmjs.org/mcp-searxng/1.0.3)).
**Upstream source.** `github.com/ihor-sokoliuk/mcp-searxng` tag `v1.0.3`
(commit `5927fae`, 2026-04-05).
**License.** MIT.
**Method.** Code review against the CSA `mcpserver-audit` framework
([ModelContextProtocol-Security/mcpserver-audit](https://github.com/ModelContextProtocol-Security/mcpserver-audit)).
The framework is a guided methodology (prompts + checks), not a CLI tool —
the checks were applied by static scanning of the upstream source tree at
tag `v1.0.3` (`git clone --branch v1.0.3 https://github.com/ihor-sokoliuk/mcp-searxng.git`)
plus `npm audit --omit=dev` for runtime dependencies.

## Disposition

**Accept.** Zero findings against the production dependency tree
(`npm audit --omit=dev` → 0 vulnerabilities). No code-level findings.
Default behaviour is conservative (stdio transport, opt-in HTTP server,
opt-in hardening, optional bearer auth, dedicated `http-security.ts`
module). In our deployment the server runs in its own container on
the `clawx-isolated` bridge with no API keys in its environment.

## Checks applied

| Check | Result |
|---|---|
| Credential management (CWE-798, CWE-522) | PASS — `AUTH_USERNAME`/`AUTH_PASSWORD`/`MCP_HTTP_AUTH_TOKEN`/`SEARXNG_URL` read from env only; no hard-coded secrets in `src/`. |
| Dynamic content execution (CWE-94) | PASS — no `eval`, no `Function(...)`, no `child_process.exec`. |
| Network port binding (CWE-200) | INFO — `app.listen(port)` in `src/index.ts:251` binds to `0.0.0.0` by Node/Express default. In our deploy the container exposes only on the `clawx-isolated` rootless-podman bridge. |
| Transport security (CWE-319) | PASS — outbound to SearXNG configurable via `SEARXNG_URL` (operator chooses http/https); no TLS-bypass flags (`rejectUnauthorized: false`, etc.) in `src/`. Dedicated `src/tls-config.ts`. |
| HTTP-server hardening | PASS — `src/http-security.ts` provides opt-in `MCP_HTTP_HARDEN=true` with bearer-token auth, origin allow-list, DNS-rebinding protection, and host allow-list. When `harden=true`, `validateHttpSecurityConfig` enforces that `MCP_HTTP_AUTH_TOKEN` and `MCP_HTTP_ALLOWED_ORIGINS` are set — fail-closed. |
| Authentication comparison | INFO — bearer-token check uses JS `===` (not constant-time). String-equality timing leakage on a single comparison per request is in practice negligible for 32+ byte tokens but worth tracking. |
| Logging of sensitive data | PASS — `src/resources.ts` only reports `hasAuth`/`hasProxy` booleans, never the env values themselves. Default config-exposure path masks `SEARXNG_URL` unless `MCP_HTTP_EXPOSE_FULL_CONFIG=true` is set explicitly. |
| Supply chain — runtime deps | PASS — `npm audit --omit=dev` reports 0 vulnerabilities across `@modelcontextprotocol/sdk`, `cors`, `express`, `node-html-markdown`, `undici`. |
| Supply chain — dev deps | INFO — `npm audit` (incl. dev) flags 5 transitive advisories under `hono`/`ip-address`/`fast-uri`/`express-rate-limit`/`@hono/node-server`. All come from devDependencies (test/inspector tooling); never reach the runtime container. |
| Pinning / supply chain | PASS — version pinned exactly (`MCP_SEARXNG_VERSION=1.0.3`) plus `--ignore-scripts` on the `npm install -g` invocation in `bootc/clawx-runtime/Containerfile`. |

## Detailed findings

### F-MS-001 — Bearer-token comparison uses string equality

**Severity.** Informational.
**Where.** `src/http-security.ts` → `isRequestAuthorized`:
```ts
return headerValue === `Bearer ${config.authToken}` || headerValue === config.authToken;
```
**Risk.** Single-comparison timing-channel leakage of token contents over
many adversarial requests. JavaScript string `===` is generally not
constant-time; however, the V8 fast path makes the per-byte difference
small and a 32-byte cryptographic token has 256-bit entropy that any
remote timing attack would need to recover bit-by-bit.
**Disposition.** **Accept** for the current deployment — `MCP_HTTP_HARDEN`
is OFF in tank-agent-os (we rely on bridge-isolation; the mcp-searxng
container is unreachable outside the `clawx-isolated` bridge).
Note for any future deployment that does enable `MCP_HTTP_HARDEN` on a
network-exposed surface: prefer a constant-time comparator
(`crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b))`).
**Upstream.** Worth filing a tiny PR; not blocking our adoption.

### F-MS-002 — Default `0.0.0.0` HTTP bind

**Severity.** Informational.
**Where.** `src/index.ts:251` (`app.listen(port, …)` with no host arg).
**Risk.** In a deployment that exposes the container on a routable
interface, the HTTP transport would be reachable on all interfaces.
**Disposition.** **Accept.** Our deployment runs the container on the
internal `clawx-isolated` rootless-podman bridge (`bootc/rootfs/etc/
containers/systemd/users/1000/mcp-searxng.container` — Network=
`clawx-isolated.network`, no `PublishPort`). The container has no
host-side port mapping, and the bridge does not reach the host network
or the egress proxy. Future operators choosing different network
topology should set `MCP_HTTP_HARDEN=true` or wrap the container in
their own isolation.

## Recommended ongoing controls

- Watch upstream `mcp-searxng` releases for security advisories; re-run
  `npm audit --omit=dev` against any new version before bumping
  `MCP_SEARXNG_VERSION`.
- If a future deployment exposes the mcp-searxng HTTP endpoint outside
  the bridge, mandate `MCP_HTTP_HARDEN=true` and constant-time auth.

## Raw outputs

`npm audit --omit=dev` against `mcp-searxng@1.0.3` (run 2026-05-19):

```
found 0 vulnerabilities
```

Full audit including dev tree flagged 5 transitive advisories — all
contained to test/inspector tooling, not present in the runtime image.
