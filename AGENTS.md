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

All 4 satellite skills (`load`, `advise`, `review`, `publish`) shipped in 6.0.0 via tickets WK-7 through WK-10 and are operational. See `CHANGELOG.md` for per-version detail.

## Initial setup

After installing:

- Set the locale with `/wk:doer locale es` (or any ISO 639-1 code). The setting persists at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (outside the versioned plugin cache, so it survives upgrades).
- Set opt-in flags via the helper if you want them: `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh set-flag stage4_parallel_subagents true`.
- `lessons/`: the 5 initial lessons ship with the plugin. The plugin accumulates more as tickets close.

## Repo structure

```
doer/
|- .claude-plugin/{plugin,marketplace}.json
|- skills/                              # 5 user-invocable skills
|  |- doer/SKILL.md                     # 9-stage orchestrator (lean dispatcher)
|  |  |- stages/                        # per-stage protocols loaded on demand
|  |  |  |- 01-ac-confirm.md ... 09-wrapup.md
|  |  |  |- _intake.md, _resume.md, _commands.md
|  |- load/{SKILL.md, examples.md, lib/extract-acs.sh}
|  |- advise/SKILL.md
|  |- review/{SKILL.md, examples.md}
|  |- publish/{SKILL.md, examples.md, reuse.md, edge-cases.md}
|- lib/                                 # shared protocols
|  |- principles.md                     # Core principles
|  |- narration.md                      # locale + em-dash rule
|  |- workspace-guard.md                # install check + .doer/ exclude
|  |- memory-paths.md                   # canonical paths + metadata.json schema
|  |- heartbeat.md                      # anti-compaction
|  |- stage-checklist.md                # Stage Finalization Checklist
|  |- loop.md                           # doer/reviewer convergence pattern
|  |- debugging.md                      # root-cause protocol for fixers
|  |- migrations.md                     # active migrations (>=5.0.0) + protocol header
|  |- migrations/legacy.md              # archived migrations (1.x -> 5.0.0), lazy-loaded
|  |- lock.md, inbox.md, cost.md        # per-ticket coordination
|  |- jira-transition.md                # Jira REST sub-protocol (loaded by /wk:publish)
|  |- cost-rates.json
|  |- helpers/                          # executable: lock.sh, inbox.sh, cost.sh,
|  |                                    #   cost-transcript.sh, preferences.sh
|  |- advisor-personas/                 # JSON personas for /wk:advise and /wk:review
|- scripts/refresh-rates.sh
|- lessons/                             # global, cross-project (5 files)
|- tests/{helpers.sh, fixtures/}
|- AGENTS.md, README.md, CHANGELOG.md, LICENSE
```

Personal preferences (locale, opt-in flags) live OUTSIDE the repo and outside the versioned plugin cache: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (since 6.2.0).

## For a Claude session that received this repo

If the user pastes the URL of this repo and says "install this", run the ritual above.

If they ask "help me use it", read `skills/doer/SKILL.md` (lean dispatcher; it points to per-stage protocols under `skills/doer/stages/`).

If they ask "add a feature to the plugin", read `CHANGELOG.md` for the most recent shipped version, then propose a new minor/major version with a descriptive slug (NOT a `WK-N` ticket, the WK-1..WK-11 series is closed).

## License

MIT. See `LICENSE`.
