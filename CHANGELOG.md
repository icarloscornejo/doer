# Changelog

All releases follow SemVer. For migration details, see `lib/migrations.md`.

## 6.0.0 (plugin migration + WK-1 lock protocol)

**Type:** MAJOR (structural; no runtime change to the 9-stage pipeline).

### Plugin restructure

- Repo reorganized as a formal Claude Code plugin (`wk`).
- `doer` skill moved to `skills/doer/SKILL.md`. Invocation is now `/wk:doer ABC-123` (compat: `/doer ABC-123` still works).
- Official manifest added at `.claude-plugin/plugin.json` and catalog at `.claude-plugin/marketplace.json`.
- Shared protocols extracted from `SKILL.md` into `lib/`:
  - `lib/heartbeat.md` (anti-compaction)
  - `lib/migrations.md` (versioning + auto-migrate)
  - `lib/narration.md` (Core Principle 1, em-dash rule, locale)
  - `lib/workspace-guard.md`
  - `lib/memory-paths.md` (paths + `metadata.json` schema)
- Placeholders added for 4 planned satellite skills: `load`, `advise`, `review`, `publish`. Their implementations land in `WK-7` through `WK-10`.
- Stubs added for 2 future libs: `inbox.md`, `cost.md`. Implementations in `WK-2` and `WK-3`.
- `AGENTS.md` added for the marketplace install ritual.
- `ROADMAP.md` added with frozen design decisions + pending tickets.
- `README.md` updated for plugin format.

### WK-1: per-ticket lock protocol

- `lib/lock.md` operational: spec for the per-ticket lock (file at `.doer/tickets/<ID>/lock.json`, 30 min TTL, steal-if-stale, abort-if-fresh).
- `lib/helpers/lock.sh` executable: subcommands `acquire`, `touch`, `release`, `check`. No dependencies beyond bash + optionally `jq`.
- Workspace Guard: new step 7 invokes `lock.sh acquire`. If it returns non-zero, the orchestrator stops the run.
- Stage 9 wrapup: new step 10 invokes `lock.sh release`.
- Narration Protocol: every stage transition invokes `lock.sh touch` to refresh the heartbeat.
- Concurrent sessions on the same ticket fail fast with a clear message (PID + host + last touched). The user resolves manually.
- TTL override via env var `WK_LOCK_TTL_SECONDS=<seconds>`.

### Runtime

- No change in 9-stage pipeline behavior.
- `metadata.json` schema unchanged.
- Global lessons: same on-disk path; resolver updated to `${CLAUDE_PLUGIN_ROOT}/lessons/`.

### Automatic migration

In-flight tickets with `skill_version: "5.0.0"` migrate on the first `/wk:doer continue <ID>` after the plugin update. See the `5.0.0 -> 6.0.0` block in `lib/migrations.md`.

## Earlier versions

(Documented inline in the `## Versioning & Migrations` block of `skills/doer/SKILL.md`, which from 6.0.0 onward references `lib/migrations.md`.)
