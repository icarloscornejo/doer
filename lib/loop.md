# Doer/Reviewer Loop Pattern (Delta-Aware)

**Stages 4 (Code) and 5 (Code Review) use this pattern. Max iterations: 3.** Iterations 3+ rarely add value commensurate to cost; if 3 iterations don't converge, narrate and let the dev decide.

Stages 2 (Plan) and 3 (Tests) do NOT use this loop. They are single-pass with deterministic pre-checks plus an optional single retry. See those stages' files.

Stage 1 (AC Confirm) Step 6.5 is also single-pass. It does NOT use this loop.

## Findings severity (4 buckets)

| Bucket | Behavior | Examples |
|--------|----------|----------|
| **BLOCKER** | Loop continues until resolved | Failing test, missing AC coverage, security issue, broken build |
| **AUTO_FIX** | Applied automatically same iteration before convergence check | Reference to deleted function, unused import, test name stale after rename, typo |
| **SUGGESTION** | Logged to `metadata.code_review`, never applied, never blocks | "Consider extracting", "could use map instead of ifs", design tweaks |
| **INFO** | Observational only | "This file is 500 LOC", "pattern used in 3 places" |

**Test for AUTO_FIX vs SUGGESTION:** *"Is there anything to decide?"* No → AUTO_FIX. Yes (trade-off, preference, design judgment) → SUGGESTION. When in doubt → SUGGESTION (be conservative; AUTO_FIX runs without user approval).

**Convergence = zero BLOCKERs remaining.** AUTO_FIXes are applied within the same iteration, do not block convergence.

## Review entries (in `metadata.code_review`)

Stage 5 appends one object per iteration to `metadata.code_review` (a JSON array). NEVER write to a sidecar file. Shape:

```json
{
  "iteration": <N>,
  "blockers":   [{"id": "B-1", "text": "<finding>", "source": "reviewer | advisor:<persona-id>"}, ...],   // iter 1 form
  "prior_blockers_resolved":   ["B-1", ...],                                                              // iter 2+ form
  "prior_blockers_still_open": ["B-2", ...],                                                              // iter 2+ form
  "new_blockers": [{"id": "B-3", "text": "...", "source": "reviewer | advisor:<persona-id>"}, ...],     // iter 2+ form
  "auto_fixes":  [{"id": "AF-1", "text": "<mechanical change>"}, ...],
  "suggestions": [{"id": "S-1",  "text": "<observation>", "source": "reviewer | advisor:<persona-id>"}, ...],
  "info":        [{"id": "I-1",  "text": "...", "source": "reviewer | advisor:<persona-id>"}, ...],
  "verdict": "needs_revision | converged",
  "advisor_personas_ran": ["<persona-id>", ...]                                                          // iter 1 only, when stage5_advisor_personas is non-empty
}
```

The `source` field is optional and defaults to `"reviewer"` for entries written by the Stage 5 reviewer LLM and the deterministic Pre-reviewer Checks. Entries promoted from `/wk:advise` carry `"source": "advisor:<persona-id>"`. The `advisor_personas_ran` field is set on iter 1 only when `preferences.sh get-flag stage5_advisor_personas` returns a non-empty list and at least one persona ran successfully; it is absent on iter 2/3 because personas do not re-run.

The reviewer reads ONLY the most recent `metadata.code_review[-1]` entry plus prior unresolved BLOCKERs (both passed inline in the prompt). Old SUGGESTIONs stay logged for the dev but are NOT re-analyzed.

## Changelog entries (in `metadata.changelog`)

Every stage that produces output (planner, test writer, code writer, code reviewer fix-pass, runtime logger, etc.) APPENDs an entry to `metadata.changelog` (JSON array). Append-only. NEVER rewrite or compress prior entries. Shape:

```json
{
  "stage": <N>,
  "iteration": <N>,
  "kind": "initial | fixes",
  "items": [
    {"type": "decision", "text": "<one-line>"},
    {"type": "step",     "text": "<one-line>"},
    {"type": "fix",      "blocker_id": "B-1", "text": "<what + why>"},
    {"type": "auto_fix", "id": "AF-1",        "text": "<mechanical change>"}
  ]
}
```

One-line items only. No prose. Sub-agents reading the changelog look at the last 1-3 entries inline in their prompt. Terse means cheap to read AND cheap to write.

## Sub-agent delegation contract (orchestrator MUST NOT execute LLM-heavy work inline)

The orchestrator's job is to **dispatch and validate**, not to do the LLM-heavy work itself. The following stages MUST delegate via the Agent tool. The orchestrator MUST NOT inline the LLM work, regardless of ticket size or complexity:

- Stage 2 (planner)
- Stage 3 (test-writer; both BDD and direct-mode regression writer)
- Stage 4 (doer iter 1, reviewer iter 1, fixer-reviewer iter 2+, AUTO_FIX fixer, parallel subagents per group)
- Stage 5 (advisor personas, when enabled)
- Stage 7 (runtime-logger and log-analyzer sub-agents, when run)
- Stage 8 (docs-updater, when applicable)

The orchestrator may inline: state reads/writes (metadata.json, git status, file existence checks), deterministic validation (jq queries, regex, file presence), narration, and stage transitions. Anything that would consume meaningful output tokens producing artifacts (code, prose, structured findings) MUST go through Agent.

Rationale: (1) cost tracking via lib/helpers/cost.sh only fires on Agent returns; inline work is invisible to the protocol; (2) sub-agents have isolated context windows, which is necessary for read budgets to mean anything; (3) parallelism is impossible without delegation; (4) compaction-driven drift in long tickets has been observed to push the orchestrator toward inline execution. This rule exists to make that drift detectable and rejectable.

**Record cost on every Agent return.** After each Agent dispatched by the loop (doer iter 1, reviewer iter 1, AUTO_FIX fixer, iter 2+ combined fixer-reviewer), the orchestrator MUST run, best-effort:

```bash
${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh record "<TICKET-ID>" \
  --model <model-id-from-Agent-return> \
  --input <usage.input_tokens> \
  --output <usage.output_tokens> \
  --stage <N> \
  --agent <role>
```

The orchestrator MUST also increment `metadata.stages.<N>.agent_invocations` in the same step. If the return does not expose token counts, narrate `cost.sh record skipped (no usage block)` and continue. The helper is best-effort and never blocks the loop. The owning stage spec names the canonical `<role>` strings (e.g. `code-writer`, `code-reviewer`, `code-fixer-reviewer`, `auto-fix-fixer`, `advisor:<persona-id>`). See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md` and `${CLAUDE_PLUGIN_ROOT}/lib/narration.md`.

## Read budgets (per iteration, per role)

Sub-agent read budgets are SOFT limits expressed in their prompt. Goal: cap exploration cost without forbidding necessary reads. **No scratch files**: every piece of context the sub-agent needs arrives inline in the prompt (extracted from `metadata.ac`, `metadata.plan`, last N `metadata.changelog` entries, and `git diff <base>..HEAD`).

| Role | Budget |
|------|--------|
| Iter 1 doer | Up to 15 source files + lessons. Free to grep. Receives `metadata.ac` and `metadata.plan` inline. |
| Iter 1 reviewer | `git diff <base>..HEAD` + last 1-2 `metadata.changelog` entries (inline) + up to 5 source files for spot-checks. Receives `metadata.ac` and `metadata.plan` inline. |
| Iter 2+ combined fixer-reviewer | `git diff <base>..HEAD` + last 2 `metadata.changelog` entries + last `metadata.code_review` entry (all inline) + up to 3 source files specifically tied to BLOCKER targets. NO scratch reads. |
| AUTO_FIX fixer | The lines named in the AUTO_FIX list. No exploration. |

Add this line to every sub-agent prompt: *"Read budget: <N> source files. Stay within it. If a BLOCKER genuinely requires more, note the extra reads in your changelog appendix and proceed."*

## Iteration 1 (clean-slate, two agent calls)

1. MUST invoke a **doer** sub-agent via the Agent tool. It produces the artifact (the code/tests/etc. the stage owns) and returns a `changelog_appendix` object that the orchestrator persists into `metadata.changelog`. The orchestrator MUST NOT produce the artifact inline.
2. MUST invoke a **reviewer** sub-agent via the Agent tool. It returns findings JSON (BLOCKER / AUTO_FIX / SUGGESTION / INFO). Orchestrator persists as a new entry in `metadata.code_review`. The orchestrator MUST NOT perform the review inline.
3. **Apply AUTO_FIXes** (if any): MUST invoke a fixer sub-agent via the Agent tool with *"Apply each mechanically. No design changes. Return a changelog appendix with `{type: 'auto_fix', id: '<id>', text: '<change>'}` items."* The orchestrator MUST NOT apply AUTO_FIXes inline.
4. Zero BLOCKERs → converged. Narrate `"Converged. N AUTO_FIXes applied. M SUGGESTIONs logged."`, auto-proceed.
5. BLOCKERs > 0 → Iteration 2.

## Iteration 2+ (delta-aware, ONE combined agent call)

Iter 2+ is targeted fix verification. No need for fresh-eyes review on small changes the same agent just made. Halve the calls:

1. MUST invoke **ONE combined "fixer-reviewer" sub-agent via the Agent tool** with the following payload **inlined in the prompt** (NOT as file reads). The orchestrator MUST NOT perform fixing or reviewing inline:
   - `metadata.ac` (in_scope, out_of_scope)
   - `metadata.plan` (files, steps, tests)
   - Last 2 `metadata.changelog` entries (what changed and why)
   - Last `metadata.code_review` entry (prior verdict)
   - Prior BLOCKERs with IDs
   - The diff: `git diff <base>..HEAD`
   - Instruction:
     ```
     Step 1: Address each prior BLOCKER. Update code/tests in-place.
       For each fix, add to your output: {type: "fix", blocker_id: "<id>", text: "<what + why>"}

     Step 2: Self-review your fix. For each prior BLOCKER, mark RESOLVED or STILL_OPEN. Scan ONLY the lines you just touched for new issues.

     Step 3: Output JSON:
     {
       "changelog_appendix": {
         "stage": <N>, "iteration": <N>, "kind": "fixes",
         "items": [{type, text, ...}, ...]
       },
       "code_review_entry": {
         "iteration": <N>,
         "prior_blockers_resolved": ["id-1", ...],
         "prior_blockers_still_open": ["id-2", ...],
         "new_blockers": [{"id": "B-X", "text": "..."}, ...],
         "auto_fixes": [...],
         "suggestions": [...],
         "info": [...],
         "verdict": "needs_revision | converged"
       }
     }

     Read budget: 3 source files max beyond the diff.
     ```
2. Apply AUTO_FIXes (separate fixer pass if needed).
3. Remaining BLOCKERs = still_open + new. Zero → converged. Otherwise → next iteration (subject to max 3).

**Why combined:** for iter 2+, the changes are small and the reviewer would re-read the same context the doer just wrote. One agent does both with the changelog as its trail. Trade-off: weaker than fresh-eyes review, but iter 1 already had a fresh-eyes review pass, so the high-impact biases were caught upfront. The dev can always force a fresh-eyes pass by setting `metadata.stages.<N>.force_fresh_review = true`.

## Max iterations reached (3) without convergence

Narrate: *"Stage {N} did not converge after 3 iterations. {N} BLOCKERs remain: {list}. Options: 1) one more iteration, 2) accept and continue, 3) pause."* If option 1 converges → `loop_outcome = "converged"`. If option 2 → `loop_outcome = "accepted_with_residuals"`. If option 3 → leave `metadata.stages.<N>.status = "in_progress"` and do NOT set `loop_outcome` (the dev resumes later via `/doer continue`).
