# Transition Sync

Unconditional re-hydration at every stage transition and every resume, so the orchestrator's instructions survive context compaction without relying on the model's own sense of whether its context is still fresh (a self-assessment that always answers "yes" once the anchor text is sitting in a conversation summary, even when the actual rules are gone).

**At every stage transition AND at every `/doer <ID>` invocation that resumes an existing ticket (including implicit resumes from natural language like "continue" or "keep going"), the orchestrator performs this as its FIRST action, before any stage logic. No skip path.**

1. Narrate one line: *"Transition Sync."*
2. Read `./.doer/tickets/<TICKET-ID>/metadata.json` to re-establish `current_stage` and prior state (`changelog`, `code_review`, etc).
3. Read ONLY the stage file for `metadata.current_stage` (e.g. `current_stage: 4` → read `04-verify.md`, nothing else).
4. Continue with that stage's logic.

Three Read calls, no more: the orchestrator already reads metadata at every transition, this just makes the stage-file re-read unconditional instead of assumed.

**A finished stage MUST auto-proceed to the next one in the same turn** (per `lib/narration.md`'s turn-boundary rule). Stopping between stages without the dev having asked for a pause is a violation of this sync, not a valid resting point: the ticket counts as "done" only when Stage 5's closing narration (`05-wrapup.md`, Close step) has actually been shown, not when the orchestrator merely stops responding.
