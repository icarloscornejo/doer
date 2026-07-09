# Changelog

All notable changes to the Doer Work Kit. Follows SemVer. History for 1.x through 6.9.0 is archived at [`docs/CHANGELOG-archive-6x.md`](./docs/CHANGELOG-archive-6x.md).

## 7.0.0

The great slimming. Doer 6.x had grown to ~58,000 words of protocol and its maintenance cost outgrew its value; 7.0.0 rebuilds the kit around what actually earned its keep, and absorbs the two standalone skills that outperformed it in daily use.

### Added

- **`/wk:bugfix`** (absorbed and generalized): bug triage pipeline from a Jira ticket. Fetch, Charles session digest, plan-mode investigation, data-driven `app_bug` / `not_app_bug` verdict, fix-or-spike execution, on-device verification. Jira is full-token (no MCP): base URL is configurable per-project, credential is a plain env var (`JIRA_PAT` by default, name overridable per-project for people who already export theirs under another name); the token itself is never persisted. Charles→HAR conversion auto-detects `makehar` / Charles.app and degrades gracefully. Hybrid storage: control state in `./.doer/tickets/<KEY>/`, heavy artifacts in `~/Downloads/<KEY>/`.
- **`/wk:protologs`** (absorbed): temporary `PROTOLOG` debug logs over the full vertical slice of the current diff, with saturation-density checklist, forbidden-refactor detection, compile verification, and trace-free cleanup. Replaces the old Stage 7 (runtime-verify) machinery and remains standalone. Compile verification generalized beyond Gradle.
- **`lib/helpers/jira.sh`**: generic Jira REST helper (fetch / download / comment / config / set-url / set-token-env), owner of the per-project `./.doer/config.json`, shared by bugfix and doer's optional intake auto-fetch.
- **`/wk:setup`, `/wk:locale`, `/wk:jira`**: three top-level config skills. `/wk:setup` guides one-time setup for locale (global) and Jira base URL + token env var name (per-project), with an auto-detect fallback pass for the token env var name (candidates only, never values); `/wk:locale <code>` and `/wk:jira <url>` are the one-shot equivalents for a single piece.
- **`lib/state.md`**: single lean source of truth for schemas, layout, and per-stage required fields.

### Changed

- **Pipeline collapsed 9 → 5 stages:** AC + Intake (merged), Plan (now uses native plan mode instead of a planner sub-agent + deterministic check ritual), Build (tests + code + review merged into one doer/reviewer loop; the quality gate is the loop's exit criterion), Verify (delegates to protologs), Wrapup (lessons + docs check + commit message + PR description).
- **Direct/BDD strategy ritual replaced** by a one-line tests-first vs code-first criterion the orchestrator applies silently; the BDD approach itself survives (ACs as Given/When/Then, tests derived from those scenarios), what died was the ceremony of picking a strategy.
- **Per-ticket lock** reduced from a protocol + helper to ~10 lines of inline bash in the Workspace Guard (same protection: fresh lock blocks, stale lock steals, wrapup releases).
- `metadata.json` schema redesigned lean (bugfix.json style); `AC-N`/`DOER` leak prevention now also covers the `PROTOLOG` tag.
- Total protocol size: ~58,000 → ~11,000 words.

### Removed

- Satellite skills `load`, `advise`, `review`, `publish` and the advisor personas (unused in practice; `load`'s useful fetch logic lives on in `jira.sh`).
- Cost tracking (protocol, rates, reconciler, ~900 lines of bash). The harness reports cost natively.
- Migration machinery (570 lines + legacy archive). `skill_version` is still stamped; resuming a ticket across a MAJOR bump now stops with a clear message instead of auto-migrating. 9 of 10 6.x migrations were version-bump-only, evidence the machinery was overhead.
- Heartbeat / Transition Sync (compaction defense obsoleted by the harness; the stage-transition re-read rule preserves the useful part).
- Inter-stage inbox (with 5 stages, plan-to-build advisories travel inside `metadata.plan.assumptions`).
- Opt-in flags (`stage1_ac_self_review`, `stage4_per_task_gate`, `stage4_parallel_subagents`, `stage5_advisor_personas`), locale auto-detection heuristic, startup version check.

### Migration from 6.x

Completed tickets need nothing. In-flight 6.x tickets cannot resume under 7.0.0: finish them by hand or recreate them. Global lessons carry over unchanged.
