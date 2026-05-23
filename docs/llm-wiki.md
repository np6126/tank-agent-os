# LLM-Wiki

`llm-wiki` is an opt-in MCP server that gives the agent a persistent,
git-backed Markdown knowledge base — Karpathy's LLM-Wiki pattern: a
compounding knowledge artifact the agent builds and queries across
sessions. Its design, the eight wiki tools, wiki-repo setup, the
agent-side conventions, and the `wiki-clip` source clipper all live in
the separate **[mcp-llm-wiki](https://github.com/np6126/mcp-llm-wiki)**
repository, shipped here as a digest-pinned container image. **Read that
repo for everything except the tank-agent-os wiring** — this page covers
only how to turn it on here.

The server runs in its own container, isolated from the agent: it holds
ephemeral working trees, mediates every git read and write, and reaches
the git host only through the shared egress proxy. The agent talks to it
over HTTP-MCP on the `clawx-isolated` bridge.

## Enabling it on tank-agent-os

Prerequisite: one or more wiki repositories on your git host, each with
a machine account that can reach them — see
[mcp-llm-wiki § Setting up a wiki](https://github.com/np6126/mcp-llm-wiki#setting-up-a-wiki).

### 1. agent.env

Add to `~/.clawx/agent.env`:

```sh
AGENT_LLM_WIKI_URL=https://git.example.com
AGENT_LLM_WIKI_ORG=my-team
AGENT_LLM_WIKI_USER=wiki-bot-vmA
AGENT_LLM_WIKIS_RW=wiki-django,wiki-android
AGENT_LLM_WIKIS_READONLY=wiki-platform-notes
```

- `AGENT_LLM_WIKI_URL` — base URL of your git host.
- `AGENT_LLM_WIKI_ORG` — the owner namespace the wiki repos live under
  (an org or user). Defaults to `AGENT_LLM_WIKI_USER` if unset.
- `AGENT_LLM_WIKI_USER` — the per-VM machine account, used for auth and
  commit identity.
- `AGENT_LLM_WIKIS_RW` / `AGENT_LLM_WIKIS_READONLY` — the wikis this VM
  may read-write / read-only. A `wiki_save` against a read-only wiki
  returns a tool error; the git host's collaborator permission enforces
  the same split as defence in depth.

Optional: `MCP_LLM_WIKI_READ_TTL` (seconds, default 30) bounds how
stale a read can be — a read refreshes the working tree with
`git pull --rebase` at most once per window. Writes always pull first.

### 2. API token secret

```bash
printf '%s' "$LLM_WIKI_TOKEN" | clawx setup llm_wiki_token
```

The token is injected into the container as `AGENT_LLM_WIKI_TOKEN` —
never written to `agent.env` or baked into the image.

### 3. Egress proxy allowlist

The container reaches the git host over HTTPS through the egress proxy.
Add your git host to the proxy allowlist, or `git pull`/`push` fails
before the TLS handshake.

### 4. Wire and start

```bash
clawx setup
systemctl --user start llm-wiki.service
```

`llm-wiki.service` is a Quadlet-generated unit — it ships without an
`[Install]` section and is **never** auto-started, not even on
`opencode` builds, because it needs the setup above first; `start` is
how you bring it up. On first start the container clones every
configured wiki; an unreachable git host is retried with backoff
rather than crash-looping, so the agent sees a clean tool error rather
than a missing MCP server.

The server is wired into all three agent variants automatically —
nothing to configure: `gen-opencode-config` writes the `mcp.llm-wiki`
entry for `opencode`, the image ships `llm-wiki` in `claw-settings.json`
for `claw-code`, and `claude` gets it from `claude-mcp.json` via the
wrapper's `--mcp-config`. If the service is not running the wiki tools
simply do not appear, the same as any other opt-in MCP.

### 5. Install the skills

The tools alone are not enough — the agent also needs the wiki
conventions, which ship as four [Agent Skills](skills.md): a base
`llm-wiki` skill plus `llm-wiki-ingest`, `llm-wiki-query`, and
`llm-wiki-lint`. They travel inside the `llm-wiki` image at
`/usr/share/llm-wiki/skills/`, so the container started in step 4 is
the source — copy them out into the host-side skill directory:

```bash
mkdir -p ~/.clawx/skills
podman cp llm-wiki:/usr/share/llm-wiki/skills/. ~/.clawx/skills/
```

The next agent session picks them up.

## Verifying

```bash
podman ps --filter name=llm-wiki
podman logs llm-wiki        # expect "Uvicorn running on http://0.0.0.0:3100"
clawx mcp list              # llm-wiki appears among the connected MCP servers
```

For a round-trip: have the agent `wiki_save` a page and confirm the
commit landed on the git host (author = the service account); then
edit a page on your laptop and push — the agent sees it on its next
`wiki_read` within the `MCP_LLM_WIKI_READ_TTL` window.

## How agents use it

A wiki-backed agent needs no per-agent prompt telling it to use its
wiki. The base operating instructions (`/etc/clawx/CLAUDE.md`,
§ Knowledge Wiki) carry one generic rule for every agent: when an
`llm-wiki` server is available, treat the wikis it exposes as long-term
memory — consult the relevant pages before a substantive task, and file
durable results back afterward, to a read-write wiki.

The rule names no domain. Which wikis an agent has is data, set per VM
in `agent.env` (`AGENT_LLM_WIKIS_RW` / `AGENT_LLM_WIKIS_READONLY`); the
rule and the four skills stay generic.

## Trust model

`llm-wiki` is reviewed in
[`audits/llm-wiki-server-2026-05-20.md`](../audits/llm-wiki-server-2026-05-20.md).
The tank-agent-os-specific points:

- **No new egress vector** — the container can reach only the git host,
  via the proxy, like every other container.
- **Two-writable-paths invariant** — the working trees live in the
  `llm-wiki` container's own named volume (`llm-wiki-data`), not a third
  writable mount on the `clawx` container.
- **Prompt injection** — wiki pages are shared, long-lived content that
  other agents or humans may have written. `CLAUDE.md` tells the agent
  to treat them as data, not instructions; the server strips known
  injection patterns on every write — hardening, not a guarantee.
