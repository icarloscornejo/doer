# Stage 9. Wrapup (Lessons + Assumptions + Performance)

**Goal:** validate assumptions, capture lessons, persist a one-paragraph summary plus performance stats into `metadata.json`, clean `.doer/` from branch history. No `wrapup.md` sidecar (everything goes into `metadata.summary`, `metadata.performance`, `metadata.assumptions_validation`, `metadata.lessons_captured`).

## MUST-RUN steps (forcing rule, NEVER skip)

Stage 9 is a sequence of NINE numbered sub-steps. Steps 7 (commit message) and 8 (PR description) are the two most-skipped sub-steps in the wild because they fall after the visible "ticket complete" actions (history cleanup, final commit). Skipping them violates the dev's contract; they are mandatory output of every wrapup. To prevent the skip:

1. Before narrating any "Ticket complete" or "Stage 9 complete" message in step 9, the orchestrator MUST self-verify BOTH flags:
   - `metadata.stages.9.commit_message_presented` is `true` (or `"skipped"` if the dev explicitly said skip during step 7).
   - `metadata.stages.9.pr_description_presented` is `true` (or `"skipped"` if the dev replied `skip` in step 8).
2. If either flag is missing or `false`, STOP. Do NOT narrate the closing summary. Run the missing step now (jump back to step 7 or step 8 as appropriate) and ONLY THEN write the closing summary.
3. The Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) already enforces both flags as required-when-complete fields. The forcing rule above is the runtime double-check that catches the failure mode where the orchestrator advances `metadata.stages.9.status = "complete"` without having presented either artifact.

**Order of sub-steps (MUST run in this order):**

| Sub-step | What |
|---|---|
| 1 | Validate assumptions |
| 2 | Capture lessons |
| 3 | Persist summary + performance into metadata |
| 4 | Set `metadata.status = "complete"` and `stages.9` baseline fields |
| 5 | History cleanup (filter-branch) — asks for confirmation |
| 6 | Final commit (only if uncommitted real changes) |
| 7 | **Recommend final commit message** (write `commit_message_presented`) |
| 8 | **Help with PR description** (write `pr_description_presented`) |
| 9 | Final closing narration |

Steps 7 and 8 are NEVER skipped automatically. The dev may decline step 8 by replying `skip`, in which case the flag is set to the literal string `"skipped"`; the step itself still runs to capture that decision. There is no auto-skip path for either step.

1. **Validate assumptions.** Read `metadata.plan.assumptions`. For each assumption, decide VALIDATED, INVALIDATED (with reason), or UNVERIFIED based on what actually happened during Stages 4-7. Persist as `metadata.assumptions_validation`:
   ```json
   "assumptions_validation": [
     {"text": "<assumption from metadata.plan.assumptions>", "status": "VALIDATED | INVALIDATED | UNVERIFIED", "reason": "<one-line, only if INVALIDATED>"}
   ]
   ```

2. **Capture lessons (with auto-detected candidates).**

   Before asking the user, scan `metadata.json` for signals that often produce a lesson worth keeping. Build a candidate list:

   | Signal | Suggested lesson framing |
   |--------|--------------------------|
   | A looped stage (4 or 5) hit the max of 3 iterations and was accepted with residuals | "Stage <N> didn't fully converge. What unresolved class of issue is worth flagging for next time?" |
   | A looped stage took 3 iterations to converge | "Stage <N> ({name}) needed 3 iterations. What pattern made it slow?" |
   | Stage 2 or Stage 3 used its single retry (`metadata.stages.<N>.retry_used == true`) | "Stage <N> failed deterministic checks once. What kept the planner/test-writer from getting it right the first time?" |
   | Stage 7 (Runtime Verify) returned RETURN_TO_STAGE_<N> | "Runtime behavior diverged from tests. What gap in the test strategy let this through?" |
   | An assumption was marked INVALIDATED in step 1 | "Assumption '{text}' turned out wrong. What should we check up front next time?" |
   | Stage X had BLOCKERs categorized as 'security' or 'data integrity' | "A {category} BLOCKER appeared late. Is this a class of mistake we keep making?" |

   Present the candidates to the user IF any exist:
   ```
   Lesson candidates detected from this ticket:
   1. <signal>: <framing>
   2. ...

   Reply with: comma-separated numbers to accept, `add: <your lesson>` to add another, `none` to skip, or `edit <N>: <new framing>` to reword.
   ```

   For each accepted candidate, ask the user to fill in: `what happened`, `why it matters`, `takeaway`. Or accept the orchestrator's draft based on `metadata.changelog` and let the user edit. **Read budget for any agent invoked here: 0 source files.** Lessons drafting reads only `metadata.json` fields and `git log/diff`; it does NOT explore the codebase.

   If NO signals detected, ask once: *"Any lesson worth saving for future tickets? Reply with one, or `none`."* (one prompt, not multiple).

   For each lesson, write to the GLOBAL pool at `${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md` (lessons remain as files; they are cross-project knowledge, not per-ticket state). Format:
   ```markdown
   ---
   slug: <kebab-case>
   captured_from: <TICKET-ID>
   captured_at: <ISO8601>
   when_it_applies: <short context>
   ---
   ## What happened
   ## Why it matters
   ## Takeaway
   ```

   Then persist a reference to each lesson in `metadata.lessons_captured`:
   ```json
   "lessons_captured": [
     {"slug": "<kebab-case>", "takeaway": "<one-line>"}
   ]
   ```

3. **Persist summary + performance into `metadata.json`.** Delegate to a summary + performance writer sub-agent via the Agent tool. The orchestrator MUST NOT build the summary or performance object inline — this is the heaviest inline step in Stage 9 and runs with the largest accumulated context. The sub-agent has read budget 0; all inputs are inlined in the prompt.

   Sub-agent prompt skeleton:

   ```
   You are the summary and performance writer for ticket <TICKET-ID>.
   Read budget: 0 source files. All inputs are inlined below.

   == metadata.json (full dump) ==
   <full JSON dump of metadata.json>

   == git log <base>..HEAD --oneline ==
   <output>

   == git diff --stat <base>..HEAD ==
   <output>

   Produce a JSON object with exactly two keys:

   {
     "summary": "<one-paragraph plain prose: what the ticket delivered, what was actually changed, any notable surprises. No em-dashes.>",
     "performance": {
       "started":    "<ISO8601, from metadata.created_at>",
       "completed":  "<ISO8601, now>",
       "wall_clock": "<duration string>",
       "active":     "<duration string; equals wall_clock>",
       "stages": [
         {"n": 1, "name": "ac-confirm", "status": "complete", "duration": "<HH:MM:SS>", "notes": "<short free-text note, or omit>"},
         {"n": 2, "name": "plan",       "status": "complete", "duration": "...", "retry_used": false, "notes": "retry used (check A-1 incorrect)"},
         {"n": 4, "name": "code",       "status": "complete", "duration": "...", "iterations": 2, "blockers_resolved": 1},
         {"n": 6, "name": "quality-gate", "status": "skipped", "duration": "...", "notes": "no diff since last green"},
         ...
       ],

       The optional `notes` field is a short human-readable note rendered verbatim in the
       Performance table's Notes column (e.g. "retry used", "no diff since last green",
       "visual on device"). If omitted, the renderer derives a note from retry_used /
       iterations / blockers_resolved. Keep notes terse and in plain language.
       "code": {"commits": N, "files": {"total": N, "src": N, "tests": N, "docs": N}, "loc": {"add": N, "rem": N}, "tests_passing": "<X/Y>"},
       "agents": {"<agent-name>": <invocation-count>, ...},
       "convergence": {"iter1": N, "iter2+": N, "max_iter_hit": N, "avg": N},
       "reviewer_roi": "<X>/<Y> looped stages converged on iter 1 with zero BLOCKERs (<%>%). Use this over time to decide if the reviewer should become opt-in."
     }
   }

   Derive durations from stage completed_at minus the previous stage completed_at (or metadata.created_at for Stage 1). Derive LOC from the git diff --stat output. Derive agent counts from metadata.stages.*.agent_invocations. Output only the JSON object, no preamble.
   ```

   After the sub-agent returns, write the `summary` and `performance` fields into `metadata.json`. Cost attribution: set the summary-writer Agent's `description` to the canonical prefix `doer:s9:summary-writer | <free text>` when dispatching it. The transcript reconciler runs later in this stage (step 12) and reads the whole session transcript, so this Agent's tokens are captured then. No `cost.sh record` call is needed; the Agent return does not expose token counts.

   The schema written into `metadata.json` is:

   ```json
   "summary": "<one-paragraph plain prose: what the ticket delivered, what was actually changed, any notable surprises>",

   "performance": {
     "started":     "<ISO8601, from metadata.created_at>",
     "completed":   "<ISO8601, now>",
     "wall_clock":  "<duration string>",
     "active":      "<duration string; equals wall_clock since there is no pause concept>",
     "stages": [
       {"n": 1, "name": "ac-confirm", "status": "complete", "duration": "<HH:MM:SS>", "notes": "<optional short note>"},
       {"n": 2, "name": "plan",       "status": "complete", "duration": "...", "retry_used": false},
       {"n": 4, "name": "code",       "status": "complete", "duration": "...", "iterations": 2, "blockers_resolved": 1},
       ...
     ],
     "code": {"commits": <N>, "files": {"total": <N>, "src": <N>, "tests": <N>, "docs": <N>}, "loc": {"add": <N>, "rem": <N>}, "tests_passing": "<X/Y>"},
     "agents": {"<agent-name>": <invocation-count>, ...},
     "convergence": {"iter1": <N>, "iter2+": <N>, "max_iter_hit": <N>, "avg": <N>},
     "reviewer_roi": "<X>/<Y> looped stages converged on iter 1 with zero BLOCKERs (<%>%). Use this over time to decide if the reviewer should become opt-in."
   }
   ```

   No sidecar file. Everything is in `metadata.json` and the dev (or `/doer status`) reads it from there.

4. **Update `metadata.json` baseline fields (NOT yet complete).** Write `status: "complete"`, `completed_at: <ISO8601>`, and `metadata.stages.9.verified_with = <SKILL version>`. Do NOT write `metadata.stages.9.status = "complete"` here — that field is written LAST, at the end of the Stage Finalization Checklist after step 9 confirms both flags. Writing it here would misrepresent steps 5-9 as already done.

5. **PR-ready history cleanup**: remove `.doer/` from prior commits on the feature branch:
   ```bash
   DIRTY=$(git log --format=%H --diff-filter=ACMR -- '.doer/*' "<base>..HEAD" 2>/dev/null)
   ```
   If empty → skip to step 6. Otherwise:

   Confirm with the user (destructive, changes SHAs). On approval, proceed with the cleanup commands below. On decline, narrate *"Skipping history cleanup. Run /doer cleanup-history later."*

   Cleanup commands:
   ```bash
   git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
   git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
   git update-ref -d refs/original/refs/heads/<branch-name> 2>/dev/null || true
   ```
   Verify `git log --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"` is empty. Tell the user the backup ref (rollback: `git reset --hard <ref>`).

6. **Final commit** (only if uncommitted real changes, wrapup itself has none since it only writes to `.doer/`):
   ```bash
   if ! git diff --quiet || ! git diff --cached --quiet; then
     git add -A
     git commit --no-verify -m "doer(<TICKET-ID>): wrapup"
   fi
   ```

7. **Recommend a final commit message.** The dev typically squashes the per-stage commits into a single PR-ready commit. Generate a recommendation based on:
   - `metadata.ac.in_scope` (what the ticket promised)
   - `metadata.changelog` (what was actually done across all stages)
   - `git log <base>..HEAD --oneline` (commit history of the branch)

   Format MANDATORY: `<TICKET-ID>: <imperative subject line, ≤72 chars>`

   The subject line should:
   - Use imperative mood ("Add X", "Fix Y", "Refactor Z", not "Added", "Fixes", "Refactoring")
   - Be specific (mention the actual change, not just "implement ticket")
   - Stay under 72 characters total (including the `<TICKET-ID>: ` prefix)
   - Contain NO internal orchestration vocabulary (Core Principle 10): no `AC-N` labels, no `DOER` / debug-log wording, no stage names, no literal `doer`. Describe the change in plain business language. The `<TICKET-ID>: ` prefix is the issue key (e.g. `PDE-2079: `), which is expected and fine; the prohibition is on the body.

   **Validate before presenting.** After drafting, run the team-facing-artifact grep over the message text:
   ```bash
   printf '%s' "<drafted commit message>" | grep -nE '\bAC-[0-9]+\b|\bDOER\b|\bdoer\('
   ```
   If it matches (exit 0), the draft leaked an internal label. Rewrite it in plain business language and re-validate. Do NOT present a message that matches.

   Present the recommendation in a fenced code block so the dev can copy-paste:

   ````
   Recommended commit message for the squashed PR commit:

   ```
   <TICKET-ID>: <imperative subject>
   ```

   You can use this as-is or adjust it before squashing your branch commits.
   ````

   After presenting, write `metadata.stages.9.commit_message_presented = true` into `metadata.json`.

   **Offer to squash now.** Immediately after presenting the message, ask via `AskUserQuestion`:

   *"Want me to squash all branch commits into one now using the message above? I'll create a backup ref first so you can roll back."*

   Options: `Yes` / `No, I'll squash manually`.

   **If the dev says Yes:**

   a. Count commits to squash:
      ```bash
      git log <base>..HEAD --oneline
      ```
      If there is only 1 commit, narrate: *"Only one commit on the branch — nothing to squash. Continuing."* and skip to step 8.

   b. Create a backup ref:
      ```bash
      BACKUP_REF="refs/doer-backup/<TICKET-ID>-pre-squash-$(date +%s)"
      git update-ref "$BACKUP_REF" HEAD
      ```

   c. Squash all commits since `<base>` into one using soft-reset + commit:
      ```bash
      git reset --soft <base>
      git commit --no-verify -m "<recommended message>"
      ```

   d. Verify the result:
      ```bash
      git log <base>..HEAD --oneline
      ```
      Must show exactly 1 commit with the chosen message. If not, narrate the discrepancy and ask the dev how to proceed before continuing.

   e. Narrate: *"Squashed to 1 commit: `<message>`. Backup ref: `$BACKUP_REF` (rollback: `git reset --hard $BACKUP_REF`)."*

   f. Write `metadata.stages.9.squash_performed = true` and `metadata.stages.9.squash_backup_ref = "<BACKUP_REF>"` into `metadata.json`.

   **If the dev says No:** write `metadata.stages.9.squash_performed = false` into `metadata.json` and continue to step 8 unchanged.

8. **Help with the PR description.** Delegate to a PR description writer sub-agent via the Agent tool. The orchestrator MUST NOT generate the PR description inline — it has the largest context in the session and running this step inline is expensive. Cost attribution: set this Agent's `description` to the canonical prefix `doer:s9:pr-description-writer | <free text>` when dispatching it (the step 12 reconciler captures its tokens from the transcript).

   Sub-agent prompt skeleton:

   ```
   You are the PR description writer for ticket <TICKET-ID>.
   Read budget: 0 source files. All inputs are inlined below.

   == metadata.ac ==
   <JSON dump of metadata.ac>

   == metadata.changelog ==
   <JSON dump of metadata.changelog>

   == Verification summary (behavior, NOT internal labels) ==
   <Plain-language verification summary. The orchestrator MUST translate each
   metadata.stages.7.ac_verdicts entry from its AC-N label into the behavior it
   describes (pull the behavior from metadata.ac.in_scope) BEFORE inlining it
   here. Example: instead of "AC-1 PASS via unit test", write "the stale banner
   no longer re-renders after refresh (covered by unit test)". NEVER inline raw
   AC-N labels, and NEVER write "DOER logs confirmed ..." or any runtime-log /
   process wording. Write "Stage 7 skipped" if Stage 7 did not run.>

   == metadata.lessons_captured ==
   <JSON dump of metadata.lessons_captured, or [] if empty>

   == metadata.assumptions_validation ==
   <JSON dump of metadata.assumptions_validation, or [] if empty>

   == metadata.ticket_id ==
   <TICKET-ID>

   == metadata.title ==
   <ticket title>

   == PR template ==
   <template content if detected; "default" if no template was found>

   Instructions:
   - If a template was provided: fill every section using the inlined metadata above. Preserve all headings, HTML comments, /label and /cc directives verbatim. Write "> N/A for this ticket." for sections that do not apply.
   - If "default": generate a generic structure with sections: Summary, Changes, How to test, Verification, Notes (omit Notes if empty).
   - NEVER include internal orchestration labels (Core Principle 10): no `AC-N` (AC-1, AC-2, ...), no `DOER` or debug-log tags, no stage names ("Stage 4", "the reviewer"), no literal `doer`. Describe behavior and verification in plain business language (e.g. "verified on device", "unit tests pass", "the stale banner no longer re-renders"). The issue key in the title (e.g. PDE-2079) is fine; the prohibition is on internal labels in the body.
   - No em-dashes anywhere. Plain prose plus bullets. Terse, reviewers read fast.
   - Output ONLY the filled PR description as a markdown string. No preamble, no explanation.
   ```

   Before dispatching the sub-agent, auto-detect a template in the repo. Standard locations (in priority order):

   ```
   .github/PULL_REQUEST_TEMPLATE.md
   .github/pull_request_template.md
   .github/PULL_REQUEST_TEMPLATE/*.md          (multi-template folder)
   .gitlab/merge_request_templates/*.md
   .gitlab/merge_request_templates/Default.md
   docs/pull_request_template.md
   PULL_REQUEST_TEMPLATE.md                    (repo root)
   ```

   Three cases:

   **Case 1: exactly one template found.** Use it directly, no prompt. Narrate: *"Detected PR template at <path>. Filling it in."* Then proceed to fill it (logic same as "user pastes a template" below).

   **Case 2: multiple templates found** (multi-template folder). If the total number of choices (templates + `default` + `skip`) is 4 or fewer, ask via `AskUserQuestion` with one option per template plus a `default` and a `skip` option. If there are too many templates to fit (more than 2), ask as a plain-chat question instead: *"Found <N> PR templates: <numbered list>. Reply with a number to pick one, `default` for a generic structure, or `skip`."* Use the chosen one, or fall through to `default`/`skip`.

   **Case 3: no template found.** Ask via `AskUserQuestion`:

   *"No PR template detected in standard locations. Paste your team's template (markdown is fine), reply `default` for a generic structure, or `skip` to handle it yourself."*

   Three branches for case 3:

   **a. User pastes a template:** Detect every section heading and `<!-- comment -->` placeholder. Fill each section using:
   - `metadata.ac` (what was promised) for "What is the story about" / "Change Summary" / "Current bug behavior" sections.
   - `metadata.changelog` (what was actually done) for "My solution" / "My fix" / "How I solved it" sections.
   - `metadata.stages.7.ac_verdicts` (if Stage 7 ran) for "Verification" / "Testing" sections.
   - `metadata.lessons_captured` and `metadata.assumptions_validation` for "Notes" / "Risks" sections.
   - `metadata.ticket_id` and `metadata.title` for ticket ID and title.

   If a section in the template does not apply to this ticket (example: a "Regression" section in a feature ticket), keep the heading present but write `> N/A for this ticket.` so the dev sees the orchestrator considered it.

   Preserve the template verbatim: every heading, every HTML comment, every `/label` or `/cc` directive at the bottom. Only fill the body slots.

   **b. User replies `default`:** Generate a generic structure:

   ```markdown
   ## Summary
   <one-paragraph description of what this ticket delivered, taken from metadata.summary or metadata.ac.in_scope>

   ## Changes
   <bulleted list of what was implemented, taken from metadata.changelog (decision and step items)>

   ## How to test
   <bulleted list of test scenarios, taken from metadata.ac.in_scope rendered as Given/When/Then>

   ## Verification
   <if Stage 7 ran: AC verdict summary from metadata.stages.7.ac_verdicts. Otherwise: "Unit tests pass: <X/Y>.">

   ## Notes
   <relevant entries from metadata.lessons_captured or metadata.assumptions_validation (INVALIDATED items), if any. Otherwise omit this section.>
   ```

   **c. User replies `skip`:** Skip the PR description step entirely. Write `metadata.stages.9.pr_description_presented = "skipped"` into `metadata.json`. Continue to step 9.

   **Formatting rules for whatever is generated (a or b):**
   - Apply Core Principle 9 (no em-dashes anywhere; see `${CLAUDE_PLUGIN_ROOT}/lib/narration.md`).
   - Use plain prose plus bullets. No marketing language, no superlatives.
   - Keep it terse. Reviewers read PR descriptions fast.

   **Validate before presenting (Core Principle 10, mirror of Stage 5 Check D).** After the sub-agent returns and before presenting, grep the generated PR description text for leaked internal vocabulary:
   ```bash
   printf '%s' "<generated PR description>" | grep -nE '\bAC-[0-9]+\b|\bDOER\b|\bdoer\('
   ```
   If it matches (exit 0): narrate which token leaked, re-invoke the PR-description writer with an explicit instruction to remove it (or scrub the offending line inline if it is a single trivial token), then re-validate. Do NOT present a description that matches the grep. (The issue key in a title, e.g. `PDE-2079`, does not match this pattern; only `AC-N`, `DOER`, and `doer(` do.)

   Present the result in a fenced code block so it copy-pastes directly into GitHub/GitLab/etc.:

   ````
   Suggested PR description (copy-paste ready):

   ```markdown
   <generated description>
   ```
   ````

   After presenting, write `metadata.stages.9.pr_description_presented = true` into `metadata.json`.

9. **Forcing rule before final narration.** Re-read `metadata.stages.9.commit_message_presented` and `metadata.stages.9.pr_description_presented` from disk. If either is absent or literal `false`, STOP. Do NOT proceed to the closing narration. Jump back to step 7 (if `commit_message_presented` is missing) or step 8 (if `pr_description_presented` is missing) and run them now. Only after BOTH flags read `true` (or the literal `"skipped"` for `pr_description_presented`) may the orchestrator continue to the closing narration below.

10. **Release the per-ticket lock.** Run:
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/lib/helpers/lock.sh release "<TICKET-ID>"
    ```
    Idempotent. The lock file is removed; future invocations of `/wk:doer <TICKET-ID>` (e.g. `verify` on a closed ticket) will acquire fresh.

11. **Drain the inbox.** Run:
    ```bash
    PENDING=$(${CLAUDE_PLUGIN_ROOT}/lib/helpers/inbox.sh list "<TICKET-ID>" --unacked | jq 'length')
    if [ "${PENDING:-0}" -gt 0 ]; then
      echo "Wrapup: $PENDING pending inbox messages remain. Resolve before completing." >&2
      exit 1
    fi
    ${CLAUDE_PLUGIN_ROOT}/lib/helpers/inbox.sh clear "<TICKET-ID>" --acked
    ```
    Pending messages at wrapup are an anomaly; the orchestrator MUST surface them via `AskUserQuestion` and ack them out of band before continuing. Acked messages are cleared so `metadata.inbox` does not grow unbounded across reverify cycles.

12. **Surface ticket cost, then present the wrapup.** Run the transcript reconciliation first (best-effort):
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost-transcript.sh reconcile "<TICKET-ID>"
    ```

    The wrapup is presented to the dev in a FIXED order. Do NOT reorder it, and do NOT hand-build the Performance table in prose — the table is rendered by a deterministic helper and printed verbatim. (Hand-building it under heavy end-of-session context is the failure mode that drops the Tokens/Cost columns; the helper exists to prevent that.)

    **Presentation order (MANDATORY, in this exact sequence):**

    **(a) Summary — in the operating locale.** Read the locale once:
    ```bash
    LOCALE=$(${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh get-locale)
    ```
    `metadata.summary` is stored in English (it is an artifact; the PR-description writer consumes it). For the CHAT presentation, render it in `$LOCALE`: if `$LOCALE` is `en`, print `metadata.summary` verbatim; otherwise translate it into `$LOCALE` for display (the stored `metadata.summary` stays English — do NOT overwrite it). Present as:
    ```
    Summary

    <metadata.summary, rendered in $LOCALE>
    ```

    **(b) Performance — rendered by the helper, printed VERBATIM.** Run:
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh performance "<TICKET-ID>"
    ```
    Print its full output verbatim under a `Performance` heading. The helper emits the complete stage table (columns: Stage | Status | Duration | Tokens (in/out) | Cost | Notes), the `Orchestrator` and bold `TOTAL` footer rows, and the `Code:` / `Agents:` / `Convergence:` lines, all joined from `metadata.performance` and `metadata.cost.transcript_reconciled`. Do NOT rebuild any of this by hand. If the helper prints `"No performance data recorded for this ticket yet."`, something earlier failed to persist `metadata.performance`; narrate that and continue.

    **(c) Cost detail — compact.** Narrate this framing verbatim first (the dev needs the model to read the breakdown correctly):

    > *"Cost is reconciled from the session transcript: the Agent tool does not expose per-call token counts, so the breakdown below is built from each sub-agent's own session log plus the orchestrator's turns, including cache costs. The per-stage figures are in the Performance table above; the detail below is by agent and by model."*

    Then print the full output of `cost.sh status --compact` verbatim. The `--compact` flag drops the per-stage block (already shown in the Performance table) and keeps the total, by-agent, and by-model breakdowns, avoiding duplication:
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh status "<TICKET-ID>" --compact
    ```
    Do NOT paraphrase or summarize it. Two render paths:
    - Transcript total > 0: by-agent and by-model breakdown (the normal case).
    - Transcript total == 0 (or reconcile never ran): the literal `"No cost recorded for this ticket yet."` (rare; means the reconciler had nothing to read, e.g. empty `metadata.session_ids`).

    Best-effort: if `cost.sh status --compact` prints `"No cost recorded for this ticket yet."`, narrate that line as-is and continue. Cost tracking is always-on; that message means the transcript reconciler had nothing to read (likely empty `metadata.session_ids`, or the transcript directory could not be located). See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md` for the protocol.

    **(d) Closing sentence.** After the cost detail, narrate the closing sentence. This is NOT freeform — present it VERBATIM, branching ONLY on `squash_performed`. Do NOT substitute, reorder, expand, or summarize this sentence:

    - If `metadata.stages.9.squash_performed == true`: *"Ticket <TICKET-ID> complete. 1 commit on `<branch>` (squashed). Summary and performance stats persisted to .doer/tickets/<TICKET-ID>/metadata.json (`summary`, `performance`, `cost`). Run your pre-commit checks, paste the PR description above, then push and open the PR manually."*
    - Otherwise: *"Ticket <TICKET-ID> complete. {N} commits on `<branch>` (post-cleanup). Summary and performance stats persisted to .doer/tickets/<TICKET-ID>/metadata.json (`summary`, `performance`, `cost`). Run your pre-commit checks, squash with the recommended commit message above, paste the PR description above, then push and open the PR manually."*

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) before marking the ticket complete.
