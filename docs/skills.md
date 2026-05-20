# Skills

tank-agent-os exposes a single host-side skill directory that both supported
agents (`claw-code` and `opencode`) read at startup. Drop a skill in,
restart the agent session, and the skill becomes available.

## Location

```
~/.clawx/skills/
```

This is part of the existing writable mount on the clawx container. No
extra Volume= or capability change is required. `clawx-init` (the
in-container init script) creates two symlinks at every container start
so the skill directory is reachable from each agent's expected lookup
path:

| Agent | Expected path inside container | Symlinked to |
|---|---|---|
| `claw-code` | `~/.claude/skills/` | `~/.clawx/skills/` |
| `opencode` | `$XDG_CONFIG_HOME/opencode/skills/` (= `~/.clawx/xdg-config/opencode/skills/`) | `~/.clawx/skills/` |

Only one agent runs per image (`AGENT_KIND` is fixed at build), so a
single directory is sufficient even though both symlinks are always
created — the inactive symlink simply isn't read.

## Skill format

Both agents accept the SKILL.md + YAML-frontmatter convention: a
directory per skill containing a `SKILL.md`, plus any supporting files
the skill needs. **Field semantics differ between the two agents** —
the shape rhymes, the schema doesn't. Refer to each agent's own docs
for the canonical fields:

- claw-code → [Claude Code skills](https://code.claude.com/docs/en/skills)
- opencode → [opencode skills](https://opencode.ai/docs/skills/)

```text
~/.clawx/skills/
└── hello-world/
    ├── SKILL.md
    └── (optional support files)
```

Minimal `SKILL.md` that works on both:

```markdown
---
name: hello-world
description: Says hello when the operator asks for a hello-world test.
---

When the operator asks you to test the hello-world skill, respond with
"hello, world".
```

opencode-specific fields (`allowed-tools`, `license`, `metadata`) are
ignored by claw-code; Claude-Code-specific fields are ignored by
opencode. The active image only runs one agent (`AGENT_KIND` fixed at
build), so authoring a skill for the wrong agent is a no-op rather than
an error.

## Activation

Drop the skill directory in `~/.clawx/skills/` and start a new agent
session:

```bash
# opencode build
clawx run "use the hello-world skill"
# claw build
clawx prompt "use the hello-world skill"
```

No `systemctl` restart is needed for the container. Each agent rescans
its skills directory on session start.

## Removing skills

```bash
rm -rf ~/.clawx/skills/<skill-name>
```

## Trust class

A skill is **operator-instruction-level trust** — same trust class as
the root-owned `CLAUDE.md` instruction file, not the
data-not-commands class that workspace content gets. The agent loads
`SKILL.md` into its prompt at session start and treats it as
authoritative guidance from the operator. This is by design: skills
exist to extend operator intent.

Two consequences worth holding in mind:

1. **Review before drop-in.** Audit every skill (including
   third-party) before placing it in `~/.clawx/skills/`. A poisoned
   skill is closer to a poisoned operator message than to a poisoned
   README in the workspace.
2. **The agent itself can write to `~/.clawx/skills/`** — the
   directory lives inside the writable `~/.clawx/` mount. A
   prompt-injected agent could, in principle, persist its own
   self-authored SKILL.md and have it loaded as operator-level
   instructions next session. Mitigations:
   - the bounded blast radius (proxy / `scopes.json` /
     two-writable-paths) still apply to whatever the skill instructs;
     skills cannot grant the agent new tool surface beyond what the
     image already configures
   - periodic review of `~/.clawx/skills/` is the operational
     mitigation (`ls -la ~/.clawx/skills/` to spot folders the
     operator didn't drop)
   - wipe agent-authored skills: `rm -rf ~/.clawx/skills/<unexpected>`

If your threat model can't accept this trade-off, build images without
ever enabling the operator-facing skill drop-in workflow and instead
bake skills into the bootc image at build time (read-only).
See [security.md](security.md) for the full trust model and capability
boundaries that still apply regardless.
