# Changelog

All notable changes to the Doer Work Kit. Follows SemVer. History for 1.x through 6.9.0 is archived at [`docs/CHANGELOG-archive-6x.md`](./docs/CHANGELOG-archive-6x.md).

## 7.4.0

### Added

- **`wk:bugfix` entry points now persist across tickets, per repo.** Previously Stage 3 asked "do you have entry points to focus the investigation" fresh on every ticket, and the answer died with `bugfix.json` once the ticket closed, even for a topic the dev had already mapped by hand in a prior ticket ("for X always start at file Y"). A new per-repo store, `./.doer/entry-points.json` (git-excluded, same as `config.json`), holds a topic -> keywords/paths/note mapping, written only through a new helper, `lib/helpers/entrypoints.sh` (`match`/`list`/`save`/`forget`, atomic tmp+`mv` writes, same pattern as `metadata.sh`). Stage 3 now recovers matching entries before asking (validating stored paths still exist on disk, since staleness here means a file moved, not that the skill's pipeline shape changed) and offers them as the default. Capture is context-aware, not a blanket extra question: a brand-new topic prompts once to save it as a standing rule; a repeat topic where the dev accepts the stored paths as-is asks nothing and just records the confirming ticket; only a genuine change (new/different paths) prompts what to do with them. Stage 5/6 close also offers, once, to fold in a root-cause file that Stage 4 found but wasn't in the stored set, so the mapping improves with use instead of freezing at the first guess. This is a separate mechanism from `wk:doer`'s cross-project lessons pool: an entry point is a structured, per-repo file-path mapping (only ever valid in this checkout), not narrative cross-project advice.

## 7.3.0

### Fixed

- **`wk:bugfix` Stage 4's `EnterPlanMode` no longer meant one-shot.** `analyze.md` ran the HAR evidence digest, iterative `python3` parsing of network captures, inside plan mode. Plan mode does not inherit the session's own permission mode, so every one of those `Bash` calls prompted for approval individually, turning the investigation into a click-through instead of an unattended pass, even for a dev running in an auto-accept mode outside plan mode. The digest now runs in a new Stage 3 step (`Evidence Digest & Entry Points`), before `EnterPlanMode` is ever called; Stage 4 and `analyze.md` are read-only tools only (`Read`/`Grep`/`Glob`) against the codebase and the evidence Stage 3 already gathered. `wk:doer` Stage 2's `EnterPlanMode` block was audited too: it was already read-only-only (`Read`/`Grep` against the project, no `Bash`), so only the instruction wording was tightened to make that explicit and prevent the same drift.

## 7.2.6

### Fixed

- **`wk:protologs` cleanup Step 2's conflict rule was a single prose sentence, and got skipped when a conflict looked trivial.** A real incident: a `[TEMP] PROTOLOG` revert conflicted with a later fix commit touching the same lines, and instead of aborting per the existing instruction, an agent resolved the conflict by hand and ran `git revert --continue`. The end state was correct, but through an unverified mechanism: Step 3b skips phantom reconciliation on the revert path because it assumes a revert is exact by construction, and a hand-resolved revert breaks that assumption silently. Step 2 now wraps every revert in an auto-abort (`git revert --no-edit <sha> || { git revert --abort; ...; }`), so a conflicted state never persists to be resolved by hand, and states the rule as a FORBIDDEN list with the reasoning behind it. A new `PreToolUse` hook (`hooks/protolog-revert-conflict-guard.sh`) denies `git revert --continue`/`--quit` or `git commit` while `REVERT_HEAD` points at a `[TEMP] PROTOLOG` commit, as a backstop to the prose. Cleanup Step 3 also now refuses to verify or report success while a revert is still in progress.
- **This plugin's `PreToolUse` guards applied to every Claude Code session with the plugin installed, including ones with no wk skill running.** `git-commit-no-verify-guard.sh` and `protolog-temp-commit-integrity-guard.sh` denied bare `git commit` and non-`--no-verify` commits regardless of whether `wk:doer`, `wk:bugfix`, or `wk:protologs` were actually active, which surprised normal sessions doing unrelated work in a repo with the plugin installed. All three guards (plus the new revert-conflict guard above) now check for a live session marker (`./.doer/wk-session-<pid>.json`, written by `lib/helpers/session.sh`) before doing anything else, and are inert without one. The marker is written by `lib/workspace-guard.md` (doer/bugfix, keyed to the session's `$PPID`) and by `skills/protologs/SKILL.md` (standalone), and released at each skill's own wrapup.
- **`wk:bugfix`'s `not_app_bug` path never released the per-ticket lock or session marker.** It set `status=complete` and stopped without the `rm -f lock.json` / `session.sh stop` that every other terminal path runs, leaving both alive until they aged out. Its close step now releases both, matching `app_bug`'s Stage 6.

### Added

- **`wk:bugfix` Stage 6 now delivers a PR-ready commit message and PR description, same as `wk:doer`'s wrapup.** The `app_bug` path used to squash with an inline, unreviewed `<KEY>: <subject>` and never produced a PR description at all. Stage 6 now runs the delivery mechanics after `wk:protologs cleanup` and before the squash, so the squash uses the reviewed message: grep-validated candidates, then the existing squash offer with backup ref, then a PR-description writer Agent (read budget 0, template auto-detection) fed from `signals`, `plan`, and `notes`. Both land in `bugfix.json` (new `commit_message`/`pr_description` fields) in the single Stage 6 close write. `not_app_bug` is unchanged: a spike ends in a Jira comment, there is no PR to describe.
- **Commit messages are now a 3-way choice in both `wk:doer` and `wk:bugfix`, and drafts stay in plain chat.** Both skills draft THREE candidates from genuinely different angles, all grep-validated for leaked internal labels, presented as numbered plain text in the chat (never inside `AskUserQuestion`, per this plugin's golden rule on drafts). The pick itself is a short-label `AskUserQuestion` (`Option 1` / `Option 2` / `Option 3`) or an equally valid plain-chat reply. PR descriptions now present wrapped in a four-backtick fence, since the previous "fenced code block" wording left the fence width ambiguous and a triple-backtick fence breaks on a description containing its own triple-backtick "how to test" snippet.

## 7.2.5

### Fixed

- **`wk:protologs` Step 4.5's Check A/B existed but nothing forced them to actually run.** A real incident: the logger-agent violated the "no refactor" rules in 5 files (expression to block conversions, an empty `init {}`, a println split across lines, a `when` block rewrapped), and deleting only the `PROTOLOG - ` tagged lines afterward did not restore the files, it left dangling empty blocks and broken syntax. The checks that exist to catch exactly this were never run before the `[TEMP]` commit landed; a markdown "MUST run this" instruction does not survive a long session. Ships as a `PreToolUse` hook (`hooks/protolog-temp-commit-integrity-guard.sh`) that intercepts any `git commit` with a `[TEMP] PROTOLOG` message and re-runs both checks against the staged diff itself, denying the commit if a forbidden refactor or a PROTOLOG line glued to real code slips through. Applies to `wk:doer` Stage 4 and `wk:bugfix` Stage 6 alike, since both go through the same commit message pattern.
- **A code-writer's "this is technically impossible" excuse for skipping a planned step went unverified.** A real incident: a code-writer skipped implementing an interface on a new component, claiming a non-null property made it "legitimately" impossible; the reviewer traced the actual call graph and found the one production construction site always passed a non-null value, so the excuse was false and the skipped step was trivial. `wk:doer` Stage 3's code-writer now must cite real call sites and type definitions (file:line, not a paraphrase) in the changelog when claiming a planned step is inapplicable; the reviewer's scope gained a dedicated "Deviation verification" check that reads those citations itself before accepting the deviation as anything other than a BLOCKER.

### Added

- **The global lessons pool now self-prunes by MAJOR version.** `lessons/` is gitignored and local per machine, so a manual cleanup on one clone never reached any other machine with the plugin installed. Each lesson captured at `wk:doer` wrapup now stamps a `skill_version` field; Stage 1's AC confirm step, the only point in the pipeline that scans the full pool, deletes any lesson whose MAJOR is behind the current skill's MAJOR (or missing the field entirely) before loading applicable lessons. A schema/architecture rework (e.g. the 6.x to 7.0.0 collapse from 9 stages to 5) can invalidate lesson advice tied to the old pipeline, so a lesson no longer outlives a MAJOR bump on any machine that runs a ticket past it.

## 7.2.4

### Fixed

- **Plugin failed to load: "Duplicate hooks file detected."** 7.2.3 added an explicit `"hooks": "./hooks/hooks.json"` entry to `.claude-plugin/plugin.json`, but `hooks/hooks.json` is auto-discovered by convention; declaring it again in the manifest made Claude Code try to load it twice. Removed the manifest entry, the file at the standard path is enough on its own.

## 7.2.3

### Fixed

- **`wk:bugfix` Stage 5 never committed the fix before Stage 6 handed off to `wk:protologs`.** `wk:protologs`' `[TEMP]` commit mechanism (inject Step 4.6) assumes the fix underneath it is already committed, so its diff contains only PROTOLOG lines and cleanup's revert is a clean no-op. With no commit at the end of Stage 5, the fix and the injected logs landed in the same working-tree diff and had to be split apart by hand after cleanup (field incident on PDE-2841). Stage 5's `app_bug` branch now commits the fix (`--no-verify`) before Stage 6 runs.
- **`wk:bugfix` Stage 6 never squashed after `wk:protologs cleanup`.** Cleanup's revert path already documented that collapsing each `[TEMP]`/revert pair is "left to the wrapup squash (doer) or to the dev directly (standalone)" (`skills/protologs/SKILL.md`), but standalone `wk:bugfix` had no squash step of its own, leaving `[TEMP]`/revert pairs sitting in history. Stage 6 now offers the same squash-and-backup-ref pattern as `wk:doer`'s wrapup step 5.

### Added

- **`git commit` without `--no-verify` is now denied at the tool-call level**, not just documented (`lib/principles.md` #6). Ships as a plugin `PreToolUse` hook (`hooks/hooks.json` + `hooks/git-commit-no-verify-guard.sh`) so it travels with the plugin to every machine it's installed on, instead of relying on a markdown instruction surviving context drift across a long session. A commit without the flag can be silently cancelled by a repo's own pre-commit hook, which looks like a no-op failure if you're not watching for it.

## 7.2.2

### Fixed

- **Per-ticket lock could get stuck for 30 minutes on a killed session, which invited an unsafe manual bypass.** Ctrl+C never releases `lock.json` (only wrapup does), so the next session had to wait out the full staleness window even though the other process was provably dead. Worse: without a way to prove that, a session was seen improvising `rm -f lock.json` on the dev's unverifiable word that the other session was closed, exactly the "no retry, no prompt" bypass the Workspace Guard forbids, and a real risk if that word is ever wrong (two sessions racing on the same `metadata.json`). Fixed with a liveness check: the lock now records `$PPID` (the long-lived `claude` process, not the transient per-Bash-call `$$`, which dies within the same command and would make every lock look dead instantly) and, on the same host, checks it's still a `claude` process via `ps -o comm=` before honoring the 30-minute window. A dead recorded process (same host) is stolen immediately, no waiting, no trust required; a different/absent host still falls back to the original 30-minute rule, never weaker than before. `lib/workspace-guard.md` also now explicitly forbids deleting or rewriting `lock.json` by hand to route around a `LOCKED` result. Note: locks written by 7.2.1 and earlier record a shell PID that's already dead by the time they're read, so they'll be stolen immediately after upgrading; no migration needed.

## 7.2.1

### Fixed

- **`metadata.sh` threw "unbound variable" on macOS's system bash.** `init`, `read`, and `path` (any call whose `ARGS` ends up empty, i.e. no trailing jq-args) failed under `/bin/bash` (3.2, frozen there for licensing reasons) because expanding an empty array under `set -u` throws in bash 3.2, unlike bash >=4. `write` happened to dodge it since its `ARGS` is never empty. Switched to the array-safe expansion idiom `"${ARGS[@]+"${ARGS[@]}"}"`. Added a regression test that runs the affected commands under `/bin/bash` explicitly, since the rest of the suite runs under `$PATH`'s (usually newer) bash and never exercised this.

## 7.2.0

### Fixed

- **`metadata.json` / `bugfix.json` writes could get OS/EDR-locked.** Persisting a stage transition as two or more separate `Edit` calls on the same file, inside the hidden `.doer/` directory, matches a corporate EDR ransomware heuristic (automated process + hidden folder + rapid rewrite of the same inode). Observed in the field: the file got tagged `com.apple.provenance` on macOS and locked at the kernel level (EPERM on read, write, rename, even re-creation under the same name), leaving the ticket's `stages.4` inconsistent with `current_stage`. Fixed at the root with a new **`lib/helpers/metadata.sh`** helper (`init`/`read`/`write`/`path`, shared by `metadata.json` and, via `--file bugfix.json`, `wk:bugfix`'s state file): every write is one `jq` transform swapped in atomically via temp-file + `mv` (a single `rename()` syscall, never an in-place rewrite). Every stage's "Finalize"/"Persist" instruction now batches all of that transition's fields into a single `metadata.sh write` call instead of several `Edit` calls. `lib/state.md` gained a "Writing metadata.json" section: always through the helper, never a direct `Edit`/`Write`, and an explicit protocol if a write still fails (stop, do not self-heal via `mv`/`xattr`/`chflags`/`rm`, point the dev at Console.app's `endpointsecurity` filter or a cooldown retry).

### Added

- **`wk:protologs` entry point restored.** Step 2.5 asks (plain chat, optional) for an entry point/root point anchoring the vertical-slice trace, complementing the git-diff-based scope; skipped when the invoker (`wk:doer` Stage 4, `wk:bugfix` Stage 6) already supplies one.

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
