# Stage 4. Verify (On Device, via wk:protologs)

**Goal:** confirm each AC's runtime behavior on a real device/simulator using temporary `PROTOLOG` debug logs. The injection and cleanup mechanics belong to the `wk:protologs` skill; this stage orchestrates the flow around it.

## Always ask (never auto-skip)

Classify the diff first (UX only, not a skip decision): paths like `*.md`, `docs/`, CI config, version-only dependency edits are non-runtime; everything else is runtime. Then ALWAYS ask via `AskUserQuestion`:

- **All non-runtime:** *"The diff is docs/config only; likely nothing to exercise on device."* Options: `Skip Stage 4 (Recommended)` / `Run it anyway`.
- **Any runtime path:** *"Exercise the ACs on a device/simulator now?"* Options: `Run Stage 4 (Recommended)` / `Skip (you own runtime correctness)`.

On skip: `stages.4.status = "skipped"`, `skipped_reason`, `skipped_acknowledged_by = "dev"`; narrate and proceed to Stage 5. Silent auto-skip is forbidden: the heuristic can misjudge a file, and this is the only on-device check in the pipeline.

## On run

1. **Inject:** invoke `wk:protologs` via the Skill tool (inject mode). It confirms the base branch, instruments the full vertical slice of the diff (entry point → boundary → observable result, per AC), backs up pre-inject state to /tmp, and commits the logs as a `[TEMP]` commit. If protologs reports uninstrumented gaps in a slice, surface them to the dev BEFORE exercising; an uninstrumented hop is lost runtime information.
2. **Hand off:** narrate build/run instructions and the log filter (protologs prints it, e.g. `adb logcat | grep "PROTOLOG - "`). Ask the dev to exercise each AC and paste the filtered output. Persist the build command as `metadata.runtime_build_command` the first time.
3. **Analyze:** dispatch a log-analyzer Agent with `metadata.ac`, `metadata.plan`, and the pasted logs inline (read budget: 0 source files; pure analysis). It returns:
   ```json
   {"ac_verdicts": {"AC-1": "PASS | FAIL | NOT_EXERCISED"}, "evidence": {...}, "anomalies": [...],
    "recommendation": "APPROVE | RETURN_TO_BUILD | NEED_MORE_DATA", "rationale": "<one paragraph>"}
   ```
4. **Decide:** present the recommendation (translate AC labels to their behavior when narrating). `APPROVE` → cleanup. `RETURN_TO_BUILD` → cleanup first, then re-enter Stage 3 with the findings as BLOCKERs. `NEED_MORE_DATA` → keep logs, back to step 2. The dev can override; record the reason.
5. **Cleanup:** invoke `wk:protologs cleanup` via the Skill tool. It deletes every `PROTOLOG - ` line, reverts the temp commit, and verifies zero trace remains (including drift: helper vars or split expressions added only to enable logging). Do not advance while any residue exists.

## Finalize

Persist `stages.4.ac_verdicts`, validate required fields per `lib/state.md`, set `stages.4` complete, narrate *"Stage 4 complete: <verdict summary>. Continuing to Stage 5..."* and auto-proceed: read `05-wrapup.md` and ONLY that file.
