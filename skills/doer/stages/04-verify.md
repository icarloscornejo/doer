# Stage 4. Verify (On Device, via wk:protologs)

**Goal:** confirm each AC's runtime behavior on a real device/simulator using temporary `PROTOLOG` debug logs. The injection and cleanup mechanics belong to the `wk:protologs` skill; this stage orchestrates the flow around it.

## Always ask (never auto-skip)

Classify the diff first (UX only, not a skip decision):
```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-checks.sh" classify-diff <base>
```
prints `runtime` or `non-runtime`. Exit 2 means the base is unusable or git failed: stop and report it, never read it as an empty or clean result (an unusable base must not turn into `non-runtime` and a skipped Stage 4). Paths like `*.md`, `docs/`, CI config, version-only dependency edits are non-runtime; everything else is runtime). Then ALWAYS ask via `AskUserQuestion`:

- **All non-runtime:** *"The diff is docs/config only; likely nothing to exercise on device."* Options: `Skip Stage 4 (Recommended)` / `Run it anyway`.
- **Any runtime path:** *"Exercise the ACs on a device/simulator now?"* Options: `Run Stage 4 (Recommended)` / `Skip (you own runtime correctness)`.

On skip: one `metadata.sh write "<TICKET-ID>" '<filter>' --require 4:skipped` sets `stages.4.status = "skipped"`, `skipped_reason`, `skipped_acknowledged_by = "dev"` (`--require` refuses the write if any of those three is missing); narrate and proceed to Stage 5. Silent auto-skip is forbidden: the heuristic can misjudge a file, and this is the only on-device check in the pipeline.

## On run

1. **Inject:** invoke `wk:protologs` via the Skill tool (inject mode). It confirms the base branch, instruments a targeted diagnostic slice of the diff (entry point → boundary → observable result, per AC, under protologs' own hop budget), backs up pre-inject state to /tmp, and commits the logs as a `[TEMP]` commit (round 1). If the plan already identifies where an AC's flow starts, pass it as the entry point so protologs' Step 2.5 does not need to ask; otherwise let protologs ask the dev directly.
   If protologs reports uninstrumented gaps in a slice, surface them to the dev BEFORE exercising; an uninstrumented hop is lost runtime information.
2. **Hand off:** narrate build/run instructions and the log filter (protologs prints it, e.g. `adb logcat | grep "PROTOLOG - "`). Ask the dev to exercise each AC and paste the filtered output. The first time, persist the build command as `metadata.runtime_build_command` via a single `metadata.sh write`.
3. **Analyze:** dispatch a log-analyzer Agent with `metadata.ac`, `metadata.plan`, and the pasted logs inline (read budget: 0 source files; pure analysis). It returns:
   ```json
   {"ac_verdicts": {"AC-1": "PASS | FAIL | NOT_EXERCISED"}, "evidence": {"AC-1": "<string>"}, "anomalies": [...],
    "recommendation": "APPROVE | RETURN_TO_BUILD | NEED_MORE_DATA", "rationale": "<one paragraph>"}
   ```
   `evidence` is required for every PASS/FAIL AC: a string citing only the log lines that justify the verdict (joined with newlines). Replace credential-looking or personal values with `<redacted>` in `evidence`, in every `anomalies` item, and in `rationale`; only redacted text is ever persisted.
   **Cumulative logs rule:** every dispatch (the first, a re-dispatch from the NOT_EXERCISED gate, a `NEED_MORE_DATA` loop, after a quick fix) receives the pasted logs from ALL rounds of the current run captured after the last code change, so re-exercising one AC cannot erase evidence for ACs that already passed. Logs from before a quick-fix commit, or whose raw text is no longer in context, are never rebuilt: re-exercise those ACs instead.
4. **Decide:** present the recommendation (translate AC labels to their behavior when narrating).
   - `APPROVE` → NOT_EXERCISED gate, then dry run, then cleanup (step 5).
   - `NEED_MORE_DATA` → invoke `wk:protologs` again (inject mode); it commits an additional `[TEMP]` commit (round N+1) on top of round 1, keeping each round individually revertible. Back to step 2; the next analyze dispatch follows the cumulative logs rule.
   - The dev may instead ask for a quick fix while logs are still live: apply it and commit it normally (`doer(<TICKET-ID>): fix <what>`, no `[TEMP]` tag), never mixed into a logging commit; then continue exercising (logs from before the fix no longer count, see the cumulative logs rule).
   - `RETURN_TO_BUILD` → cleanup first (step 5), then re-enter Stage 3 with the findings as BLOCKERs.
   The dev can override any recommendation: ask for the override reason (turn boundary per `lib/narration.md`: end the turn, a bare `ok`/`yes`/empty reply is not a reason, ask again; never write it yourself). An override that proceeds to Finalize goes through the gate and dry run below; it is the only way to `4:complete` from `RETURN_TO_BUILD` or `NEED_MORE_DATA`.
   **NOT_EXERCISED gate:** on any path to Finalize (APPROVE, or a dev override that proceeds), for each NOT_EXERCISED AC ask separately: exercise now (back to step 2 for those ACs, cumulative logs rule applies) or accept explicitly. Acceptance needs the dev's reason in plain chat (turn boundary as above); it is recorded as `accepted_not_exercised` and the override reason is never reused for it.
   **Dry run (Finalize-bound paths only, BEFORE cleanup, never for `RETURN_TO_BUILD` or `NEED_MORE_DATA`):** write the redacted analyzer payload plus the dev's acceptance and override reasons to `.doer/tickets/<TICKET-ID>/stage4-payload.json` with the Write tool, then run the exact Finalize filter against the current document: `metadata.sh read <TICKET-ID> | jq --slurpfile v .doer/tickets/<TICKET-ID>/stage4-payload.json '<filter>' | metadata.sh check-required 4 complete -`. The whole document is validated while logs are still live, so a refusal can still be fixed by re-exercising.
5. **Cleanup:** invoke `wk:protologs cleanup` via the Skill tool. It reverts every `[TEMP]` commit from every round (fixes committed separately in step 4 are untouched), verifies zero `PROTOLOG - ` trace remains, and confirms the result compiles before reporting success. Do not advance while any residue exists or the compile check has not run.

## Finalize

Build ONE jq filter (the same text as in the dry run) that in a single pass sets `stages.4.status = "complete"`, `stages.4.completed_at`, `stages.4.ac_verdicts`, `stages.4.recommendation` (the analyzer's value, verbatim), `stages.4.evidence`, `stages.4.anomalies`, `stages.4.rationale`, and, when they apply, `stages.4.accepted_not_exercised` and `stages.4.override`. Every free-text field is read from `$v[0]`, never a literal in a command. Call `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" write "<TICKET-ID>" '<filter>' --slurpfile v .doer/tickets/<TICKET-ID>/stage4-payload.json --require 4:complete` exactly once (never `Write`/`Edit` `metadata.json` directly, see `lib/state.md`, "Writing metadata.json", for why: this is the exact transition that triggered a corporate EDR file lock when done as two separate edits). `--require` validates the required fields per `lib/state.md` against the transformed document before swapping; on failure, fix and write again as a NEW transition, but never back-fill evidence or acceptance with placeholders: re-dispatch the analyzer on the pasted logs, or ask the dev again. Delete the payload file only after the write succeeds; keep it if refused. Narrate *"Stage 4 complete: <verdict summary>. Continuing to Stage 5..."* and auto-proceed: read `05-wrapup.md` and ONLY that file.
