# Resume Flow

Entered when `/doer <TICKET-ID>` finds an existing `./.doer/tickets/<TICKET-ID>/metadata.json`. No separate "continue" verb needed.

0. Run the **Transition Sync** (`lib/sync.md`) first: narrate "Transition Sync.", then proceed to step 1 below (its metadata read satisfies the sync's step 2).

1. Read `metadata.json` (e.g. `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" read "<TICKET-ID>"`, or the `Read` tool — reads carry no lock risk, only writes do; see `lib/state.md`, "Writing metadata.json").

2. **Version stamp check.** Compare the MAJOR of `metadata.skill_version` against the MAJOR of the SKILL frontmatter version. If they differ, STOP and narrate: *"This ticket was created with skill v<old> and its schema is incompatible with v<current>. Finish it by hand or recreate it with /doer."* Do not attempt to auto-migrate.

3. If `metadata.status == "complete"`, narrate the ticket summary and stop (nothing to resume; the dev can read `metadata.json` directly or run `/doer cleanup-history`).

4. Check out `metadata.branch` if not already on it.

5. Run the **Workspace Guard + lock** inline per `lib/workspace-guard.md`. This is a precondition, not a suggestion; on failure, stop and surface it.

6. Route by `metadata.stages.<current_stage>.status`:
   - `pending` → start the stage normally.
   - `in_progress` → resume mid-stage (for Stage 3, read `metadata.code_review` to recover the loop iteration; for Stage 1, read `metadata.ac.pause_reason` and re-enter directly at the integrity/completeness resolution in `01-ac.md`'s Step 5.5, never at intake or generation).
   - `complete | skipped | imported` → data drift; correct `current_stage` to the next non-complete stage with a single `metadata.sh write` and continue.

7. Narrate *"Resuming <TICKET-ID> at Stage <N> (<name>)."* and proceed: read the current stage's file and ONLY that file. Resume is the implicit intent; do not ask for confirmation.
