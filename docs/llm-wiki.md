# LLM-Wiki

`llm-wiki` is an opt-in MCP server that gives the agent a persistent,
git-backed Markdown knowledge base — Karpathy's LLM-Wiki pattern: a
compounding artifact the agent ingests into and queries.

Where a RAG pipeline retrieves raw passages from a corpus, llm-wiki is
a curated layer the agent distils and maintains itself; the two can run
side by side as separate knowledge sources.

It is built from the separate [mcp-llm-wiki](https://github.com/np6126/mcp-llm-wiki) repository and shipped
as a digest-pinned container image. This page covers the operator
side: how to wire it up.

## Design in one paragraph

Each wiki is a **git repository** (one repo = one topic area). The
canonical store is any git host you run — GitHub, GitLab, Gitea,
Forgejo, or a plain bare repo; the server only needs `git clone`,
`pull` and `push` over HTTPS with an access token. The `llm-wiki`
container holds ephemeral working trees in its own named podman volume
(`llm-wiki-data`), re-cloned from the git host on container start.
A read tool call refreshes the working tree with `git pull --rebase`,
debounced by a TTL: the pull runs only when the last one was more than
`MCP_LLM_WIKI_READ_TTL` seconds ago (default 30), so a burst of reads
triggers at most one pull and the TTL bounds how stale a read can be.
A write (`wiki_save`, `wiki_log_append`) always pulls first, then
commits and pushes. That makes backups, audit (`git log`), human
editing, and multi-VM sharing fall out for free — they are all just git.

The container reaches the git host through the same egress proxy as
every other container; it gets no network exception.

## Tools the agent sees

`wiki_list`, `wiki_read`, `wiki_read_raw`, `wiki_search`, `wiki_save`,
`wiki_log_append`, `wiki_lint`, `wiki_graph`. The conventions for using
them (page kinds, naming, the ingest/query/lint loop) live in the
`llm-wiki` skill — see [Installing the skill](#installing-the-skill).

## Git host setup (one-time)

`llm-wiki` works with any git host that supports per-repository access
tokens. The steps below are shown for Gitea — adapt the equivalent
actions (create a user, add a repo collaborator, issue a token) for
your forge.

### 1. Create a repo per wiki

Naming convention: `wiki-<topic>` (e.g. `wiki-django`,
`wiki-android`). Each repo starts with this layout:

```
wiki-<topic>/
├── raw/            # curated source documents (operator-managed)
├── wiki/           # agent-owned Markdown pages
│   └── index.md    # category catalog
├── log.md          # append-only operations log
└── .gitattributes  # log.md merge=llm-wiki-log
                    # index.md merge=llm-wiki-index
```

`log.md` lives at the repo root; `index.md` lives in `wiki/` — the
server writes pages into `wiki/` and the log at the root. The
`.gitattributes` patterns have no slash, so they match `wiki/index.md`
and `log.md` at any depth. That file is what routes both through the
custom merge-drivers that coalesce concurrent appends; the `llm-wiki`
container installs the matching driver scripts into every clone
automatically, so the `.gitattributes` file is all the repo needs.

Seed a new wiki repo like this:

```bash
git clone https://git.example.com/<org>/wiki-<topic>.git
cd wiki-<topic>
mkdir -p raw wiki
touch raw/.gitkeep
printf '# Index\n\n' > wiki/index.md
printf '# Log\n\n' > log.md
printf 'log.md merge=llm-wiki-log\nindex.md merge=llm-wiki-index\n' > .gitattributes
git add -A && git commit -m "seed wiki structure" && git push
```

### 2. Create a service account per agent VM

Each agent VM gets its own user on the git host — `wiki-bot-<vm-id>` —
used purely as a machine identity. A per-VM account, rather than one
shared account, buys three things:

- **Audit** — commits are attributed to the VM that made them, so
  `git log` distinguishes each VM (and humans) cleanly.
- **Revocation** — each VM's token can be revoked on its own, without
  disturbing the others.
- **Scoping** — collaborator permissions are set per repo, so a VM can
  reach only the wikis it is meant to.

1. Create the user `wiki-bot-<vm-id>` on the git host.
2. Add it as a **collaborator** on each wiki repo the VM should reach,
   with **write** access for read-write wikis or **read** access for
   read-only wikis. The wiki repos live under an org (or user)
   namespace — `AGENT_LLM_WIKI_ORG` below — distinct from this service
   account.
3. Issue an **access token** for that user, scoped to repository
   read/write. (In Gitea: Settings → Applications; other forges have an
   equivalent personal-access-token page.)

The server authenticates over HTTPS with this token — no SSH keys are
involved.

## VM configuration

### 1. agent.env

Add to `~/.clawx/agent.env`:

```sh
AGENT_LLM_WIKI_URL=https://git.example.com
AGENT_LLM_WIKI_ORG=my-team
AGENT_LLM_WIKI_USER=wiki-bot-vmA
AGENT_LLM_WIKIS_RW=wiki-django,wiki-android
AGENT_LLM_WIKIS_READONLY=wiki-platform-notes
```

- `AGENT_LLM_WIKI_URL` — the base URL of your git host.
- `AGENT_LLM_WIKI_ORG` — the owner namespace the wiki repos live under
  (an org or a user). Distinct from `AGENT_LLM_WIKI_USER`, which is the
  service account used only for auth and commit identity. If unset it
  defaults to `AGENT_LLM_WIKI_USER`.
- `AGENT_LLM_WIKI_USER` — the per-VM service account.
- `AGENT_LLM_WIKIS_RW` — wikis this VM may read **and** write.
- `AGENT_LLM_WIKIS_READONLY` — wikis this VM may only read. A
  `wiki_save` against one returns a tool error. This is enforced both
  in the server and (defence in depth) by the git host's collaborator
  permission.

Optional tuning — `MCP_LLM_WIKI_READ_TTL` (seconds, default 30): a wiki
read refreshes the working tree with `git pull --rebase`, but at most
once per this window, so a burst of reads triggers a single pull. It is
the upper bound on how stale a read can be relative to the git host;
`0` pulls on every read. Writes (`wiki_save`, `wiki_log_append`) always
pull first, regardless of this setting.

### 2. API token secret

```bash
printf '%s' "$LLM_WIKI_TOKEN" | podman secret create llm_wiki_token -
```

The token is injected into the container as `AGENT_LLM_WIKI_TOKEN`
env by `sync-podman-secrets` — never written to `agent.env` or baked
into the image.

### 3. Egress proxy allowlist

The container reaches the git host over HTTPS through the egress
proxy. Add your git host to the proxy allowlist, or `git pull/push`
fails before the TLS handshake.

### 4. Wire and start

```bash
tank-clawx-secrets
systemctl --user start llm-wiki.service
podman logs llm-wiki
```

`llm-wiki.service` is a Quadlet-generated unit, so it cannot be
`systemctl enable`d — `start` is how you bring it up. It is **never**
auto-started — not even on `opencode`
builds — because it needs all the above set up first. The image ships
the Quadlet without an `[Install]` section; this step is the opt-in.

On first start the container clones every configured wiki. If the git
host is unreachable it retries with backoff rather than crash-looping,
so the agent sees a clean tool error instead of a missing MCP server.

### 5. The agent's MCP wiring

The `llm-wiki` server listens on the `clawx-isolated` bridge at
`http://llm-wiki:3100/mcp` and is wired into both agent variants
automatically — nothing to configure:

| Agent | Wiring |
|---|---|
| `opencode` | `gen-opencode-config` writes the `mcp.llm-wiki` entry into `/etc/clawx/opencode-config.json`. |
| `claw-code` | The image ships `/etc/clawx/claw-settings.json` (mounted read-only at `~/.claw/settings.json`) with `llm-wiki` in its `mcpServers` block. |

If `llm-wiki.service` is not running the agent's connection to it
fails soft and the wiki tools simply do not appear — same as the
other opt-in MCPs.

## Installing the skill

The agent needs the wiki conventions (page kinds, the ingest loop) to
use the tools well. The skill is shipped in this repo, not baked into
the image — drop it into the host-side skill directory:

```bash
mkdir -p ~/.clawx/skills/llm-wiki
cp /path/to/tank-agent-os/examples/skills/llm-wiki/SKILL.md \
   ~/.clawx/skills/llm-wiki/SKILL.md
```

The next agent session picks it up. See [skills.md](skills.md).

## Human editing

The wiki is a normal git repo — edit it like one. Clone it to your
laptop, edit the Markdown in Obsidian / VS Code / any editor, commit,
push. The agent picks up your changes on its next wiki read — reads
refresh the working tree with `git pull --rebase`, at most one pull
per `MCP_LLM_WIKI_READ_TTL` window (default 30 s). Wikilinks
(`[[page]]`) render natively in Obsidian and
VS Code (with Foam); most git-host web views show them as plain text.

## Verification

Confirm the container is up and the server is listening:

```bash
podman ps --filter name=llm-wiki
podman logs llm-wiki        # expect "Uvicorn running on http://0.0.0.0:3100"
```

`clawx mcp list` shows `llm-wiki` among the connected MCP servers on
both agent variants.

A round-trip: have the agent `wiki_save` a page, then check the commit
landed on the git host (`git log` in its web UI, author = the service
account). Then edit a page on your laptop and push; the agent sees it
on the next `wiki_read` within the `MCP_LLM_WIKI_READ_TTL` window
(<= 30 s by default).

## Trust model

`llm-wiki` is reviewed in
[`audits/llm-wiki-server-2026-05-20.md`](../audits/llm-wiki-server-2026-05-20.md).
Key points:

- **Prompt injection** — wiki pages are shared, long-lived content
  that other agents or humans may have written. `CLAUDE.md` tells the
  agent to treat them as data, not instructions. The server strips
  obvious injection patterns (HTML comments, zero-width characters,
  bidi overrides, raw HTML, inline CSS, `data:` images) on every
  write — hardening, not a guarantee.
- **Path traversal** — all path operations resolve the target and
  verify it stays under the wiki root, and reject symlinked path
  components.
- **No new egress vector** — the container can only reach the git
  host, via the proxy, like every other container.
- **Two-writable-paths invariant** — the working trees live in the
  `llm-wiki` container's own named volume (`llm-wiki-data`), not a
  third writable mount on the `clawx` container.
