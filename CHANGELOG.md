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

### WK-2: inter-stage inbox protocol

- `lib/inbox.md` operational: spec for the per-ticket inbox (`metadata.inbox` array). Three message kinds: `blocker`, `advisory`, `fyi`. Messages address a specific stage or broadcast to `*`.
- `lib/helpers/inbox.sh` executable: subcommands `post`, `list`, `ack`, `clear`. Requires `jq`. Idempotent post via `--id`.
- Narration Protocol: every stage entry drains its unacked inbox after `started_at`. `blocker` messages call `AskUserQuestion` before continuing; `advisory` and `fyi` are narrated and auto-acked in the same turn. Empty inbox is silent.
- Stage 9 wrapup: new step 11 verifies the inbox has no pending messages (anomaly path), then `clear --acked` keeps `metadata.inbox` from growing across reverify cycles.

### WK-3: per-ticket cost tracking

- `lib/cost.md` operational: spec for `metadata.cost` (totals, by_model, by_stage, unknown_models). Currency USD; rates measured per million tokens.
- `lib/cost-rates.json` seeded with current Claude rates (Opus 4.7, Sonnet 4.6, Haiku 4.5) plus a `lazy_fallback` for unknown model ids. Source: `https://claude.com/pricing#api`. TTL 7 days.
- `lib/helpers/cost.sh` executable: subcommands `record`, `total`, `status`. Lazy fallback warns to stderr and never blocks.
- `scripts/refresh-rates.sh` executable: interactive (editor) or non-interactive (`--from-stdin`); validates numeric `input_per_mtok` / `output_per_mtok`, bumps `fetched_at`.
- Narration Protocol: every Agent return that exposes token counts records to `metadata.cost`. Best-effort; missing rates or counts skip silently.
- Stage 9 wrapup: new step 12 narrates `cost.sh status`. Final narration mentions `metadata.cost` alongside `summary` / `performance`.

### Runtime

- No change in 9-stage pipeline behavior.
- `metadata.json` schema unchanged.
- Global lessons: same on-disk path; resolver updated to `${CLAUDE_PLUGIN_ROOT}/lessons/`.

### Automatic migration

In-flight tickets with `skill_version: "5.0.0"` migrate on the first `/wk:doer continue <ID>` after the plugin update. See the `5.0.0 -> 6.0.0` block in `lib/migrations.md`.

## Earlier versions

(Documented inline in the `## Versioning & Migrations` block of `skills/doer/SKILL.md`, which from 6.0.0 onward references `lib/migrations.md`.)
