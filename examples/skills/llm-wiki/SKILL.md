---
name: llm-wiki
description: >-
  Use when building or consulting a persistent knowledge wiki via the
  llm-wiki MCP server. Covers the ingest / query / lint loop, the four
  page kinds, and the naming, frontmatter, and linking conventions.
---

# llm-wiki

The `llm-wiki` MCP server exposes one or more git-backed Markdown wikis
(Karpathy's LLM-Wiki pattern: a persistent, compounding knowledge
artifact, not per-query RAG). Each wiki is a git repo with three
layers:

- `raw/` — immutable curated sources. Read with `wiki_read_raw`; never
  written.
- `wiki/` — the pages you own and maintain.
- `log.md` / `index.md` — an append-only operations log and a
  category catalog.

Every `wiki_save` and `wiki_log_append` commits and pushes; every read
pulls first, so other agents' and humans' edits are always visible.

## The three operations

### Ingest — a new source becomes wiki updates

1. `wiki_read_raw` the new source.
2. For each entity or topic it covers, `wiki_search` whether a page
   already exists.
3. `wiki_save` the new and updated pages (Karpathy's rule of thumb:
   one source touches 10–15 pages).
4. **`wiki_save` `index.md`** — add the new pages to the category
   catalog. This is the most-forgotten step; skip it and the wiki
   rots.
5. **Cross-link** — add `[[wikilinks]]` between related pages.
6. `wiki_log_append` an entry: `ingest | <source title>`.

### Query — a question becomes a synthesized answer

1. `wiki_search` for relevant pages.
2. `wiki_read` the top matches.
3. Synthesize the answer yourself.
4. *If the answer is worth keeping:* `wiki_save` it as a new
   `kind: synthesis` page (see below).

### Lint — a periodic health check

1. `wiki_lint` returns orphans, broken wikilinks, and stale pages.
2. Decide what to fix — the server never auto-fixes.
3. Apply fixes with further `wiki_save` calls.

Run `wiki_lint` at the end of any substantive ingest session.

## File naming

`lowercase_snake_case.md` — no spaces, no capitals, no dots except the
`.md` extension. Examples: `error_propagation.md`,
`mcp_security_landscape.md`. Deterministic naming keeps wikilink
resolution unambiguous.

## Frontmatter

Every page starts with a YAML block:

```yaml
---
title: Optimistic Concurrency
kind: concept
sources:
  - https://en.wikipedia.org/wiki/Optimistic_concurrency_control
  - raw/etag_paper.pdf
created: 2026-05-20
updated: 2026-05-20
---
```

## The four page kinds

Ask yourself *what am I answering?* and pick the matching `kind`:

- **`entity`** — "What is X?" A concrete referent: a person, library,
  tool, standard. Self-contained. e.g. `gitea.md`.
- **`concept`** — "What does Y mean?" An abstract pattern, principle,
  or pitfall. Definition plus examples. e.g. `prompt_injection.md`.
- **`summary`** — "How do A, B, C relate?" A map over a topic area;
  mostly links, not a knowledge store itself.
- **`synthesis`** — "Why did we decide Z?" A page compiled from other
  pages (the Query "file back to wiki" output). **Must** carry
  `derived-from: [page_a, page_b]` so its provenance is traceable.

## Linking

Default to Obsidian-style wikilinks: `[[page_name]]`,
`[[page_name|alias]]`, `[[page_name#heading]]`. Standard Markdown
links also work. Wikilinks render plain in Gitea's web UI — that is a
known limitation, not a bug.

## Discipline against error propagation

A wiki has no self-correction: a wrong synthesis propagates. Two
rules:

- Treat pages you wrote yourself with the same scrutiny as external
  sources — verify against `raw/` before re-synthesizing from them.
- If a `synthesis` page's `derived-from` chain is deeper than two
  levels, go back to `raw/` rather than synthesizing further.
