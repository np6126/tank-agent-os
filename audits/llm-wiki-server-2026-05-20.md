# llm-wiki-server audit — 2026-05-20

**Target.** `mcp-llm-wiki@sha256:b0f4906a52754c4b418c657e25f0e0aeb48c4b506e1c71dcc6ad7429d0fe10d5`.
**Upstream source.** First-party — `mcp-llm-wiki` (this is not a
third-party adoption; the server was written for tank-agent-os).
**License.** MIT.
**Method.** Code review against the CSA `mcpserver-audit` framework
([ModelContextProtocol-Security/mcpserver-audit](https://github.com/ModelContextProtocol-Security/mcpserver-audit)),
applied to the `mcp-llm-wiki` source tree. Because the server is
first-party the review is a self-audit; it is recorded here to the
same standard as a third-party adoption so the MCP adoption gate in
[docs/security.md](../docs/security.md) stays uniform.

## Disposition

**Accept.** `mcp-llm-wiki` was built security-first: a paranoid
write-side sanitiser, symlink-aware path containment, hash-pinned
Python dependencies, and no secrets baked into the image. The 70-test
suite covers each of those properties. One informational finding
(F-LW-002, Gitea token persisted in per-clone `.git/config`) is
accepted with a recommended follow-up; it does not block adoption
because the token is a per-VM scoped service-account credential and
the working-tree volume is not mounted into the agent container.

## Checks applied

| Check | Result |
|---|---|
| Credential management (CWE-798, CWE-522) | PASS — the Gitea API token arrives only as the `AGENT_LLM_WIKI_TOKEN` env var, injected from the `llm_wiki_token` podman secret. Nothing is baked into the image; no token in source. See F-LW-002 for the on-disk `.git/config` note. |
| Dynamic content execution (CWE-94) | PASS — no `eval`/`exec`/`vm` of any wiki content. The only subprocesses are `git` and `rg`, both invoked with fixed argv arrays (never a shell string), so wiki content cannot reach a command line. |
| Path traversal (CWE-22) | PASS — `path_safety.resolve_within` rejects absolute paths, `..`/`.`/empty segments (validated on the raw string before `PurePosixPath` normalises), and any symlink at any path component; it re-verifies containment after resolution. 14 dedicated tests, including the CVE-2025-53109 leaf/intermediate symlink class. |
| Write-side content sanitisation | PASS — every `wiki_save` and `wiki_log_append` strips HTML comments, zero-width characters, bidi overrides, raw HTML (outside a tiny structural whitelist), inline `style=` CSS, and `data:` image URLs. 12 tests. The strip count is mirrored into the commit message for operator visibility. |
| Telemetry / outbound analytics (CWE-200) | PASS — none. The server makes no outbound HTTP of its own; the only egress is `git` to the configured Gitea host. |
| Network port binding (CWE-200) | INFO — the MCP HTTP transport binds `0.0.0.0:3100`. In this deploy the container is published only on the `clawx-isolated` rootless-podman bridge; no `PublishPort`. Same posture as searxng / mcp-searxng / docs-mcp. |
| Authentication / authorization | INFO — the MCP endpoint itself is unauthenticated; it relies on bridge isolation, identical to the other three MCP containers. Per-wiki authorization is real: `AGENT_LLM_WIKIS_RW` vs `AGENT_LLM_WIKIS_READONLY` is enforced in the server, and Gitea collaborator permissions enforce it again upstream. |
| Concurrency / data integrity | PASS — `wiki_save` uses ETag optimistic concurrency (sha256 of on-disk bytes); writes are atomic (tmp + fsync + `os.replace`); `git push` retries on non-fast-forward with a bounded loop; `log.md`/`index.md` use custom merge-drivers so concurrent appends from multiple VMs converge. |
| Writable paths in container | PASS — the wiki working trees live in a named podman volume (`llm-wiki-data`) mounted at `/wikis`, in the `llm-wiki` container's own storage scope. This does not add a third writable mount to the `clawx` container — the two-writable-paths invariant holds. |
| Logging of sensitive data | INFO — the server logs tool names and wiki names, not page content or the token. `git` subprocess output is surfaced on error; modern git redacts in-URL credentials in its messages (see F-LW-002). |
| Supply chain — runtime deps | PASS — Python dependencies are installed with `pip install --require-hashes` from a `pip-compile --generate-hashes` lockfile (594 pinned hashes). The build refuses to produce an unpinned image. |
| Pinning / supply chain | PASS — image consumed by digest pin (`MCP_LLM_WIKI_REF`) in `bootc/Containerfile`. |
| Container base | INFO — `python:3.12-slim` (Debian). Same Debian-family trust surface as the docs-mcp base; bounded by the bridge. |

## Detailed findings

### F-LW-001 — Wiki pages are a prompt-injection-persistence surface

**Severity.** Informational — inherent to the feature, mitigated.
**Where.** The wiki content model itself.
**Risk.** A wiki is shared, long-lived content. A page poisoned in one
session — by a manipulated agent, or by a human, or by ingesting a
hostile source — is read by the next session and by other VMs. This is
the same class as opt-in memory persistence.
**Mitigation.** Three layers: (1) the write-side sanitiser strips the
established injection patterns before any content is committed; (2)
`CLAUDE.md` ships a disclaimer telling the agent to treat wiki pages
as data, not instructions, at the same trust level as workspace
content; (3) the `llm-wiki` skill instructs the agent to verify
synthesis pages against `raw/` sources. Sanitisation is hardening, not
a guarantee — the residual risk is accepted, consistent with the
memory-persistence posture in [docs/security.md](../docs/security.md).

### F-LW-002 — Gitea token persists in per-clone `.git/config`

**Severity.** Informational / low.
**Where.** `entrypoint.sh` clones each wiki with the token embedded in
the HTTPS remote URL (`https://user:token@host/...`). git stores
`remote.origin.url` verbatim in each clone's `.git/config`, so the
token lands on disk in each clone's `.git/config` inside the
`llm-wiki-data` named podman volume.
**Risk.** The token is readable by a process inside the `llm-wiki`
container or by a host user who can read the podman volume store. It
is **not** in the `clawx` agent container — that container does not
mount the volume — so the agent cannot reach it.
**Disposition.** **Accept with follow-up.** The token is a per-VM
Gitea service-account credential, scoped by collaborator permission to
only that VM's wikis, and individually revocable. Recommended
follow-up in `mcp-llm-wiki`: set the remote URL tokenless and supply
the credential via `git -c http.extraheader=` or a credential helper,
so it never persists in `.git/config`. Tracked, not blocking.

## Recommended ongoing controls

- Regenerate the dependency hashes (`pip-compile --generate-hashes`)
  on every dependency bump; never hand-edit `requirements.txt`.
- Re-pin `MCP_LLM_WIKI_REF` to the new digest on every image rebuild.
- Any change to `sanitizer.py`, `path_safety.py`, or the git-mediation
  code carries a security note in the PR and re-runs the test suite.
- Address F-LW-002 (tokenless remote URL) before the OSS release of
  `mcp-llm-wiki`.

## Raw outputs

`pytest` against `mcp-llm-wiki` inside the build image (run 2026-05-20):

```
70 passed
```
