# WK Roadmap

Living document. Captures frozen design decisions and the implementation order of pending features.

## Frozen decisions (do not renegotiate)

```
PLUGIN
  technical name:  wk
  display name:    Doer Work Kit
  version:         6.0.0 (continues lineage from doer 5.0.0)
  license:         MIT
  repo remote:     github.com/icarloscornejo/doer (unchanged)
  local dir:       ~/src/doer (unchanged)

SKILLS (5)
  /wk:doer ABC-123     core, 9-stage orchestrator (keeps SKILL.md slim)
  /wk:load PROJ-42     import from external tracker (placeholder in 6.0.0)
  /wk:advise           review with configurable personas (placeholder)
  /wk:review           review of external PRs (placeholder)
  /wk:publish ABC-123  MR + opt-in Jira transition (placeholder)

TARGET STRUCTURE
  .claude-plugin/{plugin,marketplace}.json
  skills/{doer,load,advise,review,publish}/SKILL.md
  lib/{heartbeat,migrations,narration,workspace-guard,memory-paths}.md
  lib/lock.md                        operational from 6.0.0
  lib/{inbox,cost}.md                stubs in 6.0.0, content in WK-2 / WK-3
  lib/cost-rates.json                stub in 6.0.0
  lib/helpers/                       contains lock.sh from 6.0.0
  scripts/refresh-rates.sh           stub in 6.0.0
  lessons/*.md (global)
  preferences.md (root, .md format)
  AGENTS.md (install ritual)
  README.md, CHANGELOG.md, ROADMAP.md, LICENSE

COUPLING BETWEEN SKILLS
  Pragmatic hybrid:
    strong (read/write metadata.json) for satellites internal to the pipeline
    weak (own CLI + flags) for satellites with standalone life

CONVENTIONS
  JSON for configs (manifests, presets, data) - NOT YAML
  Markdown for protocols, prose, lessons
  References to lib/ via ${CLAUDE_PLUGIN_ROOT}/lib/<file>.md
  Em-dashes prohibited (rule inherited from doer Core Principle 9)
```

## 6.0.0: structural reorganization + WK-1

Status: complete in version 6.0.0. The plugin migration (Phase 0) and the WK-1 per-ticket lock protocol ship together as a single 6.0.0 release.

See `CHANGELOG.md` for the detail.

## Pending `WK-N` tickets

Each one is executed as `/wk:doer WK-N`. Full 9-stage pipeline, lessons captured.

| # | Ticket | Type | Description |
|---|---|---|---|
| ~~WK-1~~ | ~~implement lib/lock.md + helper~~ | LIB | **Done in 6.0.0**: per-ticket lock with 30 min TTL, steal-if-stale, abort-if-fresh. PID + host + heartbeat for diagnostics |
| WK-2 | implement lib/inbox.md + helper | LIB | Inter-stage messaging: advisory / blocker / fyi |
| WK-3 | implement lib/cost.md + cost-rates.json + scripts/refresh-rates.sh | LIB | Cost tracking, weekly TTL, lazy fallback |
| WK-4 | integrate pre-flight assumptions into Stage 2 | CORE | Table of executable checks in spec before dispatching plan |
| WK-5 | integrate per-task review gate into Stage 4 | CORE | Human gate `[a]ccept / [e]dit / [r]eject / [s]kip / [v]iew-full-diff` with git reset |
| WK-6 | integrate parallel subagents into Stage 4 | CORE | Subagents in parallel for independent tasks |
| WK-7 | implement skills/load (Jira / Linear / GitHub import) | SATELLITE | Ticket import from tracker |
| WK-8 | implement skills/advise (configurable personas) | SATELLITE | JSON personas. Security / perf / mobile / a11y |
| WK-9 | implement skills/review (MR review with personas) | SATELLITE | External PR review with advisors |
| WK-10 | implement skills/publish (MR + Jira transition) | SATELLITE | Opt-in: MR creation + Jira state change |

## Plugin conventions

- JSON for configs (manifests, presets, data files). NOT YAML.
- Markdown for protocols, prose, lessons.
- Em-dashes prohibited in any output of the orchestrator or its subagents.
- References between plugin files via `${CLAUDE_PLUGIN_ROOT}/lib/<file>.md`.
- Coupling between skills: pragmatic hybrid (strong for satellites internal to the pipeline, weak for satellites with standalone life).
