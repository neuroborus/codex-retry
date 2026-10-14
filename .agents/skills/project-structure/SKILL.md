---
name: project-structure
description: Keep codex-retry minimal when adding or moving code, tests, or project guidance.
---

# Project Structure

`codex-retry` owns the complete runtime; `README.md` owns usage and behavior.
`tests/` holds offline checks. Keep runtime changes in the existing script unless
a distinct responsibility justifies another file or dependency.

Keep shared guidance in `AGENTS.md` and `.agents/skills/`. Preserve the relative
`CLAUDE.md` and `.claude/skills` symlinks. Copy only settings relevant to this
wrapper; larger projects' pipeline, build, and state conventions do not belong here.
