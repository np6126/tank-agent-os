# Claude Code agent audit — 2026-05-21

**Target.** Claude Code native single-file binary, version `2.1.140`,
platform `linux-x64` (glibc). Downloaded from
`https://downloads.claude.ai/claude-code-releases/2.1.140/linux-x64/claude`.
Binary SHA-256
`807a5d6ca063f5e03e4b7283934036a3122723b28c28e1a6978e98cf2d43d0b5`
(upstream `manifest.json`: commit `89b4b3854fac52fdb8f9970133c4afe00174b6b9`,
build date `2026-05-12`).
**Upstream.** Anthropic. Distribution host `downloads.claude.ai`; per-release
`manifest.json` with a detached GPG signature `manifest.json.sig`.
**License.** Proprietary — Anthropic Commercial Terms of Service. Unlike the
MCP servers tank-agent-os adopts (MIT), Claude Code is not open source; this
audit reviews the observable runtime behaviour and the supply-chain path, not
source.
**Method.** Not the CSA `mcpserver-audit` framework — Claude Code is the
agent, not an MCP server. The review covers the build-time supply-chain path
(`claude-builder` stage in `bootc/Containerfile`), the documented runtime
behaviour (telemetry, auto-update, settings precedence, MCP transport,
permission modes — Claude Code CLI and settings reference), and how each
interacts with the tank's containment model. The release-signing key and the
2.1.140 manifest signature were verified by hand on 2026-05-21 (`gpg --verify`
→ `GOODSIG` / `VALIDSIG` for fingerprint
`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`).

## Disposition

**Accept.** Claude Code runs as the agent inside the same OS-level
containment as `claw` and `opencode` — nftables egress lockdown, the egress
proxy, service-gator-mediated external access, the root-owned read-only
instruction file, and the two-writable-mounts invariant. Nothing in the
agent's design weakens that boundary. Its supply-chain path is stronger than
the other two agents': the release manifest carries an Anthropic GPG
signature, verified at build time against a key checked into the repo
(`bootc/keys/claude-code-release.asc`), and the binary is SHA-256-pinned
against both that manifest and an in-repo `CLAUDE_CODE_SHA256` pin.

Five items carry residual notes (F-CC-002 … F-CC-006); none blocks adoption,
and the project-config code-execution item (F-CC-003) is structurally
mitigated by `--setting-sources user`. The Build-1 empirical checks were run
on a real `AGENT_KIND=claude` VM on 2026-05-21 — see "Build-1 verification"
below: the headline controls (the hook vector, `--strict-mcp-config`, the
telemetry lockdown, the first-run seed) are confirmed; two items remain as
documented manual checks.

## Checks applied

| Check | Result |
|---|---|
| Supply chain — artifact identity | PASS — GPG signature over the release manifest verified against an in-repo trust anchor, then the binary checked against both the manifest checksum and `CLAUDE_CODE_SHA256` (`claude-builder`, `bootc/Containerfile`). No build-time key download; no `tar` step (raw binary). |
| Telemetry / non-essential outbound | MITIGATED — disabled via env kill-switches in `clawx.container` and `claude-managed-settings.json`; the egress allowlist excludes telemetry/error-reporting hosts as a structural backstop. See F-CC-002. |
| Project-scoped config — hooks (code execution) | MITIGATED — `--setting-sources user` excludes the `project`/`local` settings layers, so a workspace `.claude/settings.json` and any `SessionStart` hook it defines are never loaded. See F-CC-003. |
| Project-scoped config — agents / commands / skills / nested CLAUDE.md | INFO — settings layers are excluded as above; nested `CLAUDE.md` is data-class, covered by the trust hierarchy in the root `CLAUDE.md`. Discovery of project `.claude/agents`, `.claude/commands`, `.claude/skills` from the workspace cwd is to be confirmed at Build 1. See F-CC-004. |
| Auto-update | MITIGATED — binary mounted read-only; `DISABLE_AUTOUPDATER` / `DISABLE_UPDATES` set; update hosts not in the egress allowlist. See F-CC-005. |
| MCP transport / server set | PASS — invoked with `--mcp-config /etc/clawx/claude-mcp.json --strict-mcp-config`; all other MCP sources, including a workspace `.mcp.json`, are ignored. Native streamable-HTTP MCP — no `mcp-proxy` shim. |
| Permission model | INFO — global `bypassPermissions` via the root-owned `managed-settings.json`; Claude Code refuses `bypassPermissions` as root, and the agent runs as uid 1000. The container sandbox is the boundary, consistent with opencode's `external_directory: "allow"`. See F-CC-006. |
| First-run state | INFO — `~/.claude.json` seeded by `clawx-init` so a `podman exec` invocation does not stall on the interactive onboarding/trust prompt; ephemeral (overlay-FS, re-seeded per boot), no new writable mount. The seeded flag set was confirmed sufficient on the 2026-05-21 VM run — claude started non-interactively with no stall. |
| Network egress | PASS — model calls and native `WebFetch` flow through the injected `HTTP(S)_PROXY`; native `WebSearch` is executed server-side by the Anthropic API (no container egress). No nftables/sudoers change. |
| Writable paths | PASS — agent state (`~/.claude/`, `~/.claude.json`) lands in the ephemeral overlay-FS; the two config files are root-owned `ro` mounts. No new writable mount; two-writable-paths invariant preserved. |
| Instruction file | PASS — `/etc/clawx/CLAUDE.md` is discovered by Claude Code's parent-directory traversal from `/home/clawx/workspaces` and is root-owned read-only; the agent cannot modify it. |

## Detailed findings

### F-CC-001 — Supply chain: GPG-signed manifest

**Severity.** Informational (positive).
**Where.** `claude-builder` stage, `bootc/Containerfile`;
`bootc/keys/claude-code-release.asc`.
**Detail.** Releases from `2.1.89` onward publish a detached GPG signature
over `manifest.json`. The build imports Anthropic's release-signing key from
the in-repo trust anchor, hard-checks its fingerprint
(`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`), verifies the manifest
signature, then checks the binary SHA-256 against both the manifest's
recorded `checksum` and the `CLAUDE_CODE_SHA256` pin. Rooting trust in the
checked-in key — not a build-time key fetch — means the GPG step also covers
a record-only build. `CLAUDE_CODE_REF` must stay `>= 2.1.89`.

### F-CC-002 — Telemetry and non-essential outbound traffic

**Severity.** Mitigated — informational with required settings.
**Where.** `clawx.container` `Environment=` block;
`claude-managed-settings.json` `env` block.
**Risk.** Claude Code emits non-essential traffic (analytics, error
reporting, feedback) by default.
**Mitigation.** Both the Quadlet and the root-owned `managed-settings.json`
set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER`,
`DISABLE_UPDATES`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
`DISABLE_FEEDBACK_COMMAND`, and `DO_NOT_TRACK`. The kill-switches are
duplicated across both layers so the lockdown survives if either is altered.
Defence in depth: the egress allowlist does not include telemetry endpoints,
so an event would fail at the proxy even if a kill-switch regressed.

### F-CC-003 — Project-scoped settings can define lifecycle hooks

**Severity.** Mitigated — was a pre-adoption blocker.
**Where.** Claude Code settings precedence; `clawx` wrapper `claude)` branch.
**Risk.** Claude Code loads project- and local-scoped settings
(`.claude/settings.json`, `.claude/settings.local.json`) by walking up from
the working directory. Those files can define **hooks** — for example a
`SessionStart` hook, which runs shell code when the agent starts, before the
operator's prompt is read. The working directory is the writable
`~/workspaces` mount, so a cloned repo or a prompt-injected self-write could
plant such a file. `managed-settings.json` has highest precedence only for
*conflicting* keys; hooks are *merged* across layers, so precedence alone
does not remove a project hook.
**Mitigation.** The wrapper invokes Claude Code with `--setting-sources user`
on every interactive and headless run. Only the `user` and (always-on,
root-owned) `managed` layers are loaded; `project` and `local` are never
read, so a workspace `.claude/settings.json` — and any hook it defines — does
not load. In the tank model there is no legitimate use of project/local
settings: the operator ships none, and the workspace is untrusted content.
**Build-1 confirmation.** Verified on 2026-05-21 on an `AGENT_KIND=claude`
VM: a `SessionStart` hook planted in
`/home/clawx/workspaces/.claude/settings.json` did not fire on a real
headless run (claude authenticated and reached a session). That the wrapper
always emits `--setting-sources user` is additionally asserted VM-free by
`tools/unit-tests.sh`.

### F-CC-004 — Other project-scoped configuration

**Severity.** Informational.
**Where.** Claude Code project-config discovery.
**Detail.** Beyond settings files, Claude Code can discover project
`.claude/agents`, `.claude/commands`, `.claude/skills` and nested
`CLAUDE.md`. Nested `CLAUDE.md` is data-class and is covered by the trust
hierarchy the root `/etc/clawx/CLAUDE.md` establishes (workspace content is
data, not instructions). Whether `--setting-sources user` also suppresses
discovery of project agents/commands/skills (a separate axis from settings
files) is **to be confirmed empirically at Build 1**. If they are still
discovered, they sit at the same trust class as drop-in skills
(`docs/skills.md`) — operator-instruction-level, blast radius bounded by the
proxy / `scopes.json` / two-writable-paths controls — and the residual is
documented there and in `docs/security.md`, mitigated operationally by
periodic workspace review. Project skills, if discovered, would be markdown
guidance, not direct code execution (unlike the F-CC-003 hook vector, which
*is* closed).

### F-CC-005 — Auto-update

**Severity.** Mitigated.
**Where.** `clawx.container`; `clawx-runtime` binary mount.
**Detail.** Claude Code ships an auto-updater. Three layers prevent silent
replacement: the binary is mounted read-only (an in-place update cannot
land); `DISABLE_AUTOUPDATER` / `DISABLE_UPDATES` are set; and the update
hosts are not in the egress allowlist. Updating Claude Code is a deliberate
`CLAUDE_CODE_REF` bump and rebuild — the same audited path as any pinned
component.

### F-CC-006 — Global bypassPermissions

**Severity.** Informational.
**Where.** `claude-managed-settings.json` (`permissions.defaultMode`);
`clawx` wrapper (`--permission-mode bypassPermissions` on headless runs).
**Detail.** The agent runs with `bypassPermissions` globally. This is a
deliberate operator decision: the in-process permission prompt is a UX
feature for an interactive human reviewer and auto-rejects in the tank's
headless flows, and the OS-level container sandbox — not the agent's ACL —
is the security boundary. Consistent with opencode's `external_directory:
"allow"`. Claude Code refuses `bypassPermissions` when running as root; the
agent runs as uid 1000, so it is permitted. The wrapper also passes
`--permission-mode bypassPermissions` on headless runs as a fallback for the
case where the `managed-settings.json` mount is ever absent.

## Build-1 verification — 2026-05-21

The Build-1 empirical checks were run on a freshly built `AGENT_KIND=claude`
VM, with claude authenticated by a Claude subscription (see
"Authentication" below). Results:

- **First-run state — confirmed.** The `~/.claude.json` seed
  (`hasCompletedOnboarding`, `hasTrustDialogAccepted`, `theme`,
  `autoUpdaterStatus`) is sufficient: claude started non-interactively with
  no onboarding/trust stall and headless `-p` runs completed. No
  `perProjectState` or `customApiKeyResponses` entry was needed.
- **F-CC-003, project SessionStart hook — confirmed.** A hostile
  `SessionStart` hook planted in the workspace did not fire on a real
  headless run; `--setting-sources user` excludes the project layer.
- **`.mcp.json` / `--strict-mcp-config` — confirmed.** With a hostile
  `.mcp.json` in the workspace, the agent's session MCP set was exactly the
  four baked servers — the injected `evil-injected` server did not appear.
- **F-CC-002, telemetry env — confirmed present.** All seven kill-switch
  variables are set in the running container. The egress-proxy log showing
  no telemetry traffic during a session remains a manual review (the log
  lives off-VM).
- **F-CC-004, project agents/commands/skills — still open.** The
  settings-file vector is closed (above); discovery of project
  `.claude/agents`, `.claude/commands`, `.claude/skills` from the workspace
  cwd was not separately exercised and stays a manual check. If discovered,
  they are operator-instruction-class markdown guidance (see
  `docs/skills.md`), not direct code execution.
- **Subcommand pass-through list — re-check on bump.** Verified against the
  published CLI reference for the `2.1.x` line, not the pinned binary's
  `--help`; re-check on each `CLAUDE_CODE_REF` bump.

## Authentication

Claude Code authenticates with an Anthropic API key (`anthropic_api_key`
secret → `ANTHROPIC_API_KEY`, pay-as-you-go API billing) or a Claude
subscription. For a Pro/Max/Team/Enterprise subscription, a long-lived
OAuth token from `claude setup-token` is stored as the
`claude_code_oauth_token` secret and wired to `CLAUDE_CODE_OAUTH_TOKEN` by
`sync-podman-secrets`. Either is a rootless Podman secret injected as a
container env var — never written to `agent.env` or the image. The
2026-05-21 VM verification used the subscription path.

## Recommended ongoing controls

- On each `CLAUDE_CODE_REF` bump: re-pin `CLAUDE_CODE_SHA256` from the
  GPG-verified manifest, and re-check the claude subcommand pass-through list
  in the `clawx` wrapper against the CLI reference for the new version.
- Keep `CLAUDE_CODE_REF >= 2.1.89` — earlier releases ship no signed
  manifest and the GPG step would have nothing to verify.
- Watch upstream for renames of the telemetry kill-switch env vars; a rename
  would silently re-enable telemetry until the Quadlet and
  `managed-settings.json` are updated.
- Re-verify the release-signing key fingerprint if Anthropic rotates it; the
  in-repo `bootc/keys/claude-code-release.asc` is the trust anchor.

## Raw outputs

Manifest signature verification (run 2026-05-21):

```
[GNUPG:] GOODSIG  BAA929FF1A7ECACE Anthropic Claude Code Release Signing <security@anthropic.com>
[GNUPG:] VALIDSIG 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ...
```
