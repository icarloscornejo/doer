# Stage 6. Quality Gate (Validation, Not Loop)

**Goal:** fast sanity check. No agents. Just run tests, with a skip when the diff hasn't changed since the last green run.

## Setup

The last green test run is tracked in `metadata.last_green_sha`. Stages 4 and 5 update this field whenever they finish a successful test suite execution:
```json
{
  "last_green_sha": "<HEAD SHA at the moment all tests passed; MUST be the full 40-char output of `git rev-parse HEAD`, never abbreviated>",
  "last_green_test_command": "<the command that produced green>"
}
```

## Stage 6 logic

1. Detect the repo's test command (`npm test`, `pytest`, `./gradlew test`, etc.). If unclear, ask the user once and persist as `metadata.test_command`.

2. **Skip-safe check.** Read `metadata.last_green_sha`. If it equals `git rev-parse HEAD` AND `metadata.last_green_test_command` matches the current test command, skip the test run entirely:
   ```
   Quality gate: HEAD unchanged since Stage 4/5 last green run (<sha>).
   Skipping re-run. Continuing to Stage 7.
   ```
   Set `metadata.stages.6.status = "complete"`, `metadata.stages.6.skipped_reason = "no diff since last green"`, run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`), end turn.

3. **Otherwise run the full test suite.**

4. **If any test fails:** narrate the failures and ask: *"Tests failing: {list}. Options: 1) Return to Stage 4 to fix, 2) Return to Stage 5 to re-review, 3) Pause for manual fix. Which?"*

5. **If all tests pass:**
   - Persist a brief summary in `metadata.stages.6.test_summary = "<N>/<N> tests passed in <duration>"` (counts and timing only; the dev's terminal already has the full output, no need to duplicate it on disk).
   - Update `metadata.last_green_sha = <full 40-char output of git rev-parse HEAD; MUST NOT abbreviate>` and `metadata.last_green_test_command`.
   - Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`).
   - Narrate *"Quality gate passed: <N>/<N> tests green. Continuing to Stage 7."* and proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/07-runtime-verify.md` and ONLY that file.
