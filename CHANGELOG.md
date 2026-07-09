# Changelog

All notable changes to the Doer Work Kit. Follows SemVer. History for 1.x through 6.9.0 is archived at [`docs/CHANGELOG-archive-6x.md`](./docs/CHANGELOG-archive-6x.md).

## 7.1.0

Fixes from the first round of 7.0.0 field reports: an auth gap, a cleanup incident, and three things "the great slimming" cut too close.

### Fixed

- **`jira.sh` now supports Atlassian Cloud.** It only spoke Bearer auth (Jira Server/DC); Cloud (`*.atlassian.net`) rejects Bearer with a 403 and requires HTTP Basic (`email:api_token`). New optional config key `jira_auth_email` + `jira.sh set-auth-email <email>` switches the three curl calls (fetch/download/comment) to Basic; unset, behavior is unchanged. Errors now point Cloud users at the right fix.
- **Protologs cleanup could corrupt code.** The inject agent sometimes wrote `.also { println("PROTOLOG - ...") }` glued to the same line as a `when` branch or a constructor's closing paren; the cleanup `sed` deleted the whole line, taking real code with it, and the Step 4.5 safety check didn't catch it because the offending line does contain the `PROTOLOG - ` tag. Fixed on three fronts: the skill now only allows two line shapes (a bare `println(...)`, or a bare `.also { println(...) }` on its OWN line continuing the previous expression); Step 4.5 gained a second check that flags any `PROTOLOG - ` line that isn't one of those two shapes; and inject now commits each round of logs as a `[TEMP]` commit, so cleanup reverts them instead of text-matching with `sed` (sed remains a fallback for sessions with no `[TEMP]` commit). Multiple rounds of "more logs" and any fix requested mid-verification each land in their own commit, so a revert never touches the other. Cleanup no longer reports success without a clean `git grep` AND a clean compile.

### Restored (regressions from 7.0.0's slimming)

- **Per-step commits in Stage 3 (Build).** The convergence commit collapsed tests + implementation + review fixes into one commit; restored to one commit per step (tests, implementation, each review-fix round) so a regression traces to the exact step, same as pre-7.0.0. The wrapup squash still collapses everything before the PR.
- **AC self-review (Stage 1).** A cheap agent-based review comparing the AC draft against the original description/ACs, one round (a second only if it found something structural), applying safe fixes and promoting real contradictions to Open Questions before the dev ever sees the draft.
- **Transition Sync.** A minimal, unconditional re-hydration step (`lib/sync.md`) at every stage transition and resume: re-read metadata, re-read the current stage file, and now an explicit rule that a finished stage auto-proceeds in the same turn instead of silently stopping (the failure mode that had devs asking manually whether a ticket had actually finished).

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
