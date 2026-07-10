# Stage 4. Verify (On Device, via wk:protologs)

**Goal:** confirm each AC's runtime behavior on a real device/simulator using temporary `PROTOLOG` debug logs. The injection and cleanup mechanics belong to the `wk:protologs` skill; this stage orchestrates the flow around it.

## Always ask (never auto-skip)

Classify the diff first (UX only, not a skip decision): paths like `*.md`, `docs/`, CI config, version-only dependency edits are non-runtime; everything else is runtime. Then ALWAYS ask via `AskUserQuestion`:

- **All non-runtime:** *"The diff is docs/config only; likely nothing to exercise on device."* Options: `Skip Stage 4 (Recommended)` / `Run it anyway`.
- **Any runtime path:** *"Exercise the ACs on a device/simulator now?"* Options: `Run Stage 4 (Recommended)` / `Skip (you own runtime correctness)`.

On skip: `stages.4.status = "skipped"`, `skipped_reason`, `skipped_acknowledged_by = "dev"`; narrate and proceed to Stage 5. Silent auto-skip is forbidden: the heuristic can misjudge a file, and this is the only on-device check in the pipeline.

## On run

1. **Inject:** invoke `wk:protologs` via the Skill tool (inject mode). It confirms the base branch, instruments the full vertical slice of the diff (entry point → boundary → observable result, per AC), backs up pre-inject state to /tmp, and commits the logs as a `[TEMP]` commit (round 1). If the plan already identifies where an AC's flow starts, pass it as the entry point so protologs' Step 2.5 does not need to ask; otherwise let protologs ask the dev directly.
   If protologs reports uninstrumented gaps in a slice, surface them to the dev BEFORE exercising; an uninstrumented hop is lost runtime information.
2. **Hand off:** narrate build/run instructions and the log filter (protologs prints it, e.g. `adb logcat | grep "PROTOLOG - "`). Ask the dev to exercise each AC and paste the filtered output. Persist the build command as `metadata.runtime_build_command` the first time.
3. **Analyze:** dispatch a log-analyzer Agent with `metadata.ac`, `metadata.plan`, and the pasted logs inline (read budget: 0 source files; pure analysis). It returns:
   ```json
   {"ac_verdicts": {"AC-1": "PASS | FAIL | NOT_EXERCISED"}, "evidence": {...}, "anomalies": [...],
    "recommendation": "APPROVE | RETURN_TO_BUILD | NEED_MORE_DATA", "rationale": "<one paragraph>"}
   ```
4. **Decide:** present the recommendation (translate AC labels to their behavior when narrating).
   - `APPROVE` → cleanup (step 5).
   - `NEED_MORE_DATA` → invoke `wk:protologs` again (inject mode); it commits an additional `[TEMP]` commit (round N+1) on top of round 1, keeping each round individually revertible. Back to step 2.
   - The dev may instead ask for a quick fix while logs are still live: apply it and commit it normally (`doer(<TICKET-ID>): fix <what>`, no `[TEMP]` tag), never mixed into a logging commit; then continue exercising.
   - `RETURN_TO_BUILD` → cleanup first (step 5), then re-enter Stage 3 with the findings as BLOCKERs.
   The dev can override any recommendation; record the reason.
5. **Cleanup:** invoke `wk:protologs cleanup` via the Skill tool. It reverts every `[TEMP]` commit from every round (fixes committed separately in step 4 are untouched), verifies zero `PROTOLOG - ` trace remains, and confirms the result compiles before reporting success. Do not advance while any residue exists or the compile check has not run.

## Finalize

Persist `stages.4.ac_verdicts`, validate required fields per `lib/state.md`, set `stages.4` complete, narrate *"Stage 4 complete: <verdict summary>. Continuing to Stage 5..."* and auto-proceed: read `05-wrapup.md` and ONLY that file.
