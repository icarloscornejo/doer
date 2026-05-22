# Doer Work Kit (`wk`)

Claude Code plugin for end-to-end execution of development tickets. Takes a pre-defined ticket from acceptance criteria to implementation-ready code on a feature branch, just before the PR.

## Install

```bash
# 1. Register the marketplace
claude plugin marketplace add https://github.com/icarloscornejo/doer.git

# 2. Install the plugin
claude plugin install wk@wk

# 3. Verify
claude plugin list
```

After installing, the 5 skills are available:

```
/wk:doer ABC-123       # 9-stage pipeline orchestrator (core skill)
/wk:load <ID>          # import a ticket from Jira / Linear / GitHub (operational)
/wk:advise             # review specs/ACs/code with configurable personas (operational)
/wk:review <pr-ref>    # review external PRs (operational)
/wk:publish ABC-123    # create PR/MR + transition Jira (opt-in, operational)
```

All 4 satellite skills (`load`, `advise`, `review`, `publish`) shipped in 6.0.0 via tickets WK-7 through WK-10 and are operational. See ROADMAP.md and CHANGELOG.md for details.

## Initial setup

After installing:

- Set the locale with `/wk:doer locale es` (or any ISO 639-1 code). The setting persists at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (outside the versioned plugin cache, so it survives upgrades).
- Set opt-in flags via the helper if you want them: `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh set-flag stage4_parallel_subagents true`.
- `lessons/`: the 5 initial lessons ship with the plugin. The plugin accumulates more as tickets close.

## Repo structure

```
doer/
|- .claude-plugin/plugin.json     # official manifest
|- .claude-plugin/marketplace.json
|- skills/                        # 5 skills
|  |- doer/                       # orchestrator (operational)
|  |- load/                       # operational (WK-7, shipped in 6.0.0)
|  |- advise/                     # operational (WK-8, shipped in 6.0.0)
|  |- review/                     # operational (WK-9, shipped in 6.0.0)
|  |- publish/                    # operational (WK-10, shipped in 6.0.0)
|- lib/                           # shared protocols
|  |- heartbeat.md                # anti-compaction
|  |- migrations.md               # versioning + auto-migrate
|  |- narration.md                # Core Principle 1, em-dash rule, locale
|  |- workspace-guard.md          # install check + .doer/ exclude
|  |- memory-paths.md             # canonical paths + metadata.json schema
|  |- lock.md                     # operational (WK-1, shipped in 6.0.0)
|  |- inbox.md                    # operational (WK-2, shipped in 6.0.0)
|  |- cost.md                     # operational (WK-3, shipped in 6.0.0)
|  |- cost-rates.json             # seeded rates (WK-3, shipped in 6.0.0)
|  |- helpers/                    # executable scripts (lock.sh, inbox.sh, cost.sh, cost-transcript.sh, preferences.sh)
|  |- advisor-personas/           # JSON personas for /wk:advise (WK-8, shipped in 6.0.0)
|- scripts/refresh-rates.sh       # operational (WK-3, shipped in 6.0.0)
|- lessons/                       # global, cross-project (5 files)
|- ROADMAP.md                     # design decisions + roadmap
```

Personal preferences (locale, opt-in flags) live OUTSIDE the repo and outside the versioned plugin cache: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (since 6.2.0).

## For a Claude session that received this repo

If the user pastes the URL of this repo and says "install this", run the ritual above.

If they ask "help me use it", read `skills/doer/SKILL.md` (it is the orchestrator and contains the full 9-stage flow).

If they ask "add a feature to the plugin", check `ROADMAP.md` for the planned `WK-N` ticket order.

## License

MIT. See `LICENSE`.
