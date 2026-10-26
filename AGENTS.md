# bitwize-music — OpenCode adapter

This repository is a Claude Code plugin for AI music production (Suno). It is
being driven from **OpenCode**, using the same `skills/` tree and the same Python
MCP server. This file is the OpenCode-specific override layer. `CLAUDE.md` is
also loaded for the album workflow, status model, and domain rules — where the
two disagree on harness mechanics, this file wins.

## Harness differences (read this first)

- **Plugin root**: Claude Code expands `${CLAUDE_PLUGIN_ROOT}` in skill text.
  OpenCode does not. Replace it with:
  `/home/pwn/claude-ai-music-skills`
  Every `reference/`, `genres/`, `templates/`, and `tools/` path resolves there.
- **Claude-only frontmatter is inert**: `model`, `effort`, `prerequisites`,
  `allowed-tools`, and `argument-hint` in `SKILL.md` files do nothing here.
  Treat declared model tiers (`opus`/`sonnet`/`haiku`) as a complexity hint, not
  as configuration — everything runs on the session's selected model.
- **Slash commands** are OpenCode commands under `.opencode/commands/`. The
  Claude forms `/bitwize-music:<skill>` become `/bitwize-music/SKILL_ID`.
  You can also load any skill directly with the `skill` tool by its directory
  ID (for example `suno-engineer`), or mention `@suno-engineer` in a prompt.
- **Hooks do not run.** `hooks/hooks.json` is Claude-format and is not loaded.
  Status auto-advancement, version-sync, and other hook behavior must be done
  explicitly with MCP tools when relevant.
- **No marketplace install.** The plugin is used from this checkout; the MCP
  server is configured in `opencode.json` (and in the global config, so it also
  works from album folders under `~/music-projects`).
- **Slash-command references inside skills**: when a skill says to run
  `/bitwize-music:X` or "invoke the X skill", load skill `X` with the `skill`
  tool. Do not try to execute it as a shell command.
- **Sub-agent references**: when a skill says to dispatch sub-agents or use the
  Task tool, use the `subagent` tool (usually `agent: general`) or do the steps
  sequentially. There is no Claude Task tool here.

## Skills are authoritative

Before acting on a task, load the matching skill and follow it, including any
supporting files it points at. The skill bodies contain the craft rules that
make the output usable. Do not paraphrase a skill from memory.

Routing highlights:

| User intent | Skill ID |
|---|---|
| New album | `new-album`, then `album-conceptualizer` |
| Plan concept/tracklist | `album-conceptualizer` |
| Resume / what next | `resume`, `next-step` |
| Research (documentary) | `researcher` + `researchers-*`, then `verify-sources` |
| Write lyrics | `lyric-writer` (auto-pairs with `suno-engineer`) |
| Polish lyrics | `lyric-refiner` |
| Pronunciation fixes | `pronunciation-specialist` |
| Lyrics QC | `lyric-reviewer`, `voice-checker`, `plagiarism-checker` |
| Suno prompt/settings | `suno-engineer` |
| Final pre-generation gate | `pre-generation-check` |
| Import Suno audio/stems | `import-audio` |
| Mix / master | `mix-engineer`, `mastering-engineer` |
| Promo / release | `promo-director`, `promo-writer`, `release-director` |
| Sheet music | `sheet-music-publisher` |

## MCP server

`bitwize-music-mcp` is configured as a local stdio server. Prefer its tools over
reading files ad hoc:

- State: `list_albums`, `list_tracks`, `get_album`, `get_track`, `rebuild_cache`
- Gates: `run_pre_generation_gates`, `run_release_readiness_check`
- Content: `format_for_clipboard`, `get_reference`, `load_override`
- Lyrics analysis: syllable/rhyme/readability/repetition tools
- Audio: mixing, mastering, QC, promo-video tools

If a tool returns "config not found", `~/.bitwize-music/config.yaml` is missing
or incomplete. The required keys are `artist.name`, `paths.content_root`,
`paths.audio_root`, and `paths.documents_root`.

## Workflow guardrails

Pipeline: **Concept → Research → Write (+Suno prompt) → Refine → QC/Verify →
Generate on Suno → Import → Mix → Master → Promo → Release**.

Hard gates — never skip:

1. Human source verification before generation on any source-based track.
2. `pre-generation-check` passing before a track goes to Suno.
3. A ✓ in the Generation Log before a track becomes `Final`.
4. `has_suno_link` set before a track becomes `Final`.

Instrumental tracks (`instrumental: true` + `**Instrumental** | Yes`) skip the
lyric workflow and go straight to `suno-engineer`.

Track statuses: `Not Started → Sources Pending → Sources Verified → In Progress
→ Generated → Final`.

Album statuses: `Concept → [Research Complete → Sources Verified] → In Progress
→ Complete → Released`.

Never put real artist/band names in a Suno Style Box. Use
`reference/suno/artist-blocklist.md`; the Artist Names gate blocks generation.

## Repository development

This section applies only when changing the plugin itself, not when producing
music with it.

- `make check` before any push (ruff + bandit + mypy + pytest).
- Version files must stay in sync: `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`.
- Active development is on `develop`; `main` is release-only.
