# service-gator

`service-gator` runs as a second rootless Quadlet owned by the `clawx` user.
It provides scoped access to external services such as GitHub, GitLab, Forgejo,
and JIRA without baking raw PATs into the image.

The upstream image is pinned to a specific digest in `bootc/Containerfile`
(`SERVICE_GATOR_IMAGE` + `SERVICE_GATOR_REF`). As of this writing the canonical
upstream namespace is `ghcr.io/lobstertrap/service-gator` — older versions
of this repo tracked `ghcr.io/cgwalters/service-gator`, which stopped
rebuilding in Feb 2026.

The container sees workspaces at:

```text
/workspaces
```

which maps to:

```text
~clawx/workspaces
```

The exact `claw-code` MCP wiring is intentionally not baked into the image yet.
Credentials for external services should be supplied after boot through the
`clawx` user's rootless Podman secret store.

Supported secret names:

```text
gh_token
gitlab_token
forgejo_token
jira_api_token
```

Example:

```bash
sudo -iu clawx
printf '%s' "$GH_TOKEN" | podman secret create gh_token -
tank-clawx-secrets
systemctl --user restart service-gator.service
```

`tank-clawx-secrets` writes a user Quadlet drop-in that mounts those secrets
under `/run/secrets`, matching the `*_TOKEN_FILE` environment used by the
`service-gator` container.

## Scopes

service-gator enforces an explicit allowlist: the agent can only access
repositories and projects listed in `~clawx/.config/service-gator/scopes.json`.
Any repository not listed is rejected regardless of which tokens are configured.
This is the primary mechanism for limiting what the agent can reach through
service-gator.

Configure before starting the service:

```bash
sudo -iu clawx
mkdir -p ~/.config/service-gator
cp /usr/share/tank-os/scopes.json.example ~/.config/service-gator/scopes.json
$EDITOR ~/.config/service-gator/scopes.json
systemctl --user restart service-gator.service
```

### Permission reference

Each GitHub / GitLab / Forgejo repository entry accepts these boolean fields:

| Field | Controls |
|---|---|
| `read` | Read repo content, issues, PRs |
| `push-new-branch` | Create or update Git refs (required for any push) |
| `create-draft` | Open draft PRs / MRs |
| `pending-review` | Manage pending PR reviews (GitHub, Forgejo) |
| `approve` | Approve MRs (GitLab only) |
| `write` | Full write access — implies all other permissions |
| `require-fork` | Restrict pushes to forks of the repo only |

JIRA uses a slightly different schema: per-project, per-issue permissions
plus a top-level `global_read` switch.

```jsonc
"jira": {
  "global_read": false,           // allow read across ALL projects
  "projects": {
    "PROJ": { "read": true, "comment": false, "create": false, "write": false }
  },
  "issues": {
    "PROJ-123": { "read": true, "comment": false, "write": false }
  }
}
```

`global_read` is convenient when issue-level permissions are too granular but
you still want write to be project-scoped. `comment` was added recently and
controls whether the agent can post comments separately from the heavier
`write` permission.

`push-new-branch` and `create-draft` are independent: you can allow branch
pushes without allowing PR creation, or vice versa.

The `require-fork` flag adds a second check — service-gator verifies via API
that the target is actually a fork before allowing the push.

> **Security note:** `write`, `push-new-branch`, and `create-draft` all allow
> the agent to write arbitrary content to external repositories. A manipulated
> agent could use these to exfiltrate data it has read from the workspace.
> Grant only the minimum permissions the task requires.

See `examples/service-gator/scopes.json.example` for a template covering
GitHub, GitLab, Forgejo, and Jira.

## Supported Services and Extensibility

service-gator currently supports four services: GitHub, GitLab, Forgejo/Gitea,
and Jira. Each is implemented as a hardcoded Rust module in the service-gator
source. The `scopes.json` file controls access permissions within these services
but cannot add new ones.

There is no plugin system. If you need a service not on this list, the options
are:

**Fork service-gator** — add a new `src/<service>.rs` module that implements
the service's API client and exposes methods annotated with `#[tool(...)]`. The
`#[tool_router]` macro registers them automatically. This requires Rust knowledge
and familiarity with the MCP protocol.

**Run an additional MCP server alongside service-gator** — tank-agent-os
already ships two opt-in MCPs on this pattern: SearXNG via `mcp-searxng`
(see [web-search.md](web-search.md)) and developer-docs lookup via
`docs-mcp` (see [docs-lookup.md](docs-lookup.md)). Both run as their own
Quadlets on the `clawx-isolated` network. The trade-off is that they
operate outside service-gator's scoping and audit model — and new MCPs
must pass the [MCP adoption gate](security.md#mcp-adoption-gate) before
landing in the image.

**Wait for upstream** — the service-gator roadmap lists Google Docs, Linear,
Slack, and Confluence as planned additions, as direct implementations rather
than a plugin mechanism.
