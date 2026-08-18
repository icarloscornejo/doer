# Doer Work Kit (`wk`)

Claude Code plugin with four work skills: `/wk:doer` (ticket execution, 5 stages), `/wk:bugfix` (bug triage from Jira, fix-or-spike), `/wk:replay` (force a captured network response or internal flag into the app's source to reproduce a bug on device), `/wk:protologs` (temporary runtime debug logs). Plus three config skills: `/wk:setup` (guided), `/wk:locale`, `/wk:jira`.

## Install

```bash
claude plugin marketplace add https://github.com/icarloscornejo/doer.git
claude plugin install wk@wk
claude plugin list
```

Initial setup (locale, per-project Jira config) is in `README.md` → Setup.

## Repo structure

```
doer/
|- .claude-plugin/{plugin,marketplace}.json
|- skills/
|  |- doer/SKILL.md                    # 5-stage orchestrator (lean dispatcher)
|  |  |- stages/                       # per-stage protocols, loaded on demand
|  |  |  |- 01-ac.md 02-plan.md 03-build.md 04-verify.md 05-wrapup.md
|  |  |  |- _resume.md, _commands.md
|  |- bugfix/{SKILL.md, analyze.md, templates/mini-spike.md}
|  |- replay/SKILL.md                  # forces a network response or flag to reproduce a bug on device
|  |- protologs/SKILL.md
|  |- setup/SKILL.md, locale/SKILL.md, jira/SKILL.md   # config skills
|- lib/                                # shared protocols
|  |- principles.md                    # core principles (10)
|  |- narration.md                     # turn boundaries + locale + em-dash rule
|  |- workspace-guard.md               # .doer/ exclusion + per-ticket lock (inline bash)
|  |- state.md                         # schemas: metadata.json, bugfix.json, layout, required fields
|  |- loop.md                          # doer/reviewer convergence pattern (Stage 3)
|  |- debugging.md                     # no fix without root cause
|  |- helpers/{preferences.sh, jira.sh, metadata.sh, entrypoints.sh}
|- hooks/                              # PreToolUse guards (see hooks/hooks.json)
|  |- git-commit-no-verify-guard.sh
|  |- protolog-temp-commit-integrity-guard.sh, protolog-revert-conflict-guard.sh
|  |- replay-temp-commit-integrity-guard.sh, replay-revert-conflict-guard.sh
|  |- replay-restore.py                # canonical REPLAY block stripper, shared by the guard and cleanup's fallback
|- lessons/                            # global, cross-project
|- tests/helpers.sh                    # smoke tests for the helper scripts
|- tests/hooks.sh                      # smoke tests for the PreToolUse guards
|- docs/CHANGELOG-archive-6x.md        # archived 1.x-6.x history
|- AGENTS.md, README.md, CHANGELOG.md, LICENSE
```

Personal preference (locale only) lives OUTSIDE the repo at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json`, global across every project. Jira config (base URL + token env var name; the token itself is never stored) is per-project at `./.doer/config.json`, since different repos can point at different Jira instances. The bugfix entry-points map (topic -> investigation files) is also per-project, at `./.doer/entry-points.json`: unlike the global lessons pool, its paths only ever resolve inside this exact checkout.

## For a Claude session that received this repo

- "Install this" → run the ritual above.
- "Help me use it" → read `skills/doer/SKILL.md` (dispatcher; it points at the per-stage files).
- "Add a feature to the plugin" → read `CHANGELOG.md` for the latest version, propose a new SemVer bump with a descriptive slug. There is no migration machinery: if a change breaks the `metadata.json` schema, bump MAJOR (in-flight tickets refuse to resume across MAJORs and say so).

## License

MIT. See `LICENSE`.
