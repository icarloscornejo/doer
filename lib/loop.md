# Doer/Reviewer Loop Pattern (Delta-Aware)

Used by Stage 3 (Build). **Max 3 iterations.** Beyond that, cost outpaces value; the dev decides.

## Findings severity (4 buckets)

| Bucket | Behavior | Examples |
|---|---|---|
| **BLOCKER** | Loop continues until resolved | Failing test, missing AC coverage, security issue, broken build |
| **AUTO_FIX** | Applied automatically in the same iteration | Reference to a deleted function, unused import, stale test name, typo |
| **SUGGESTION** | Logged to `metadata.code_review`, never applied, never blocks | "Consider extracting", design tweaks |
| **INFO** | Observational only | "This file is 500 LOC" |

**AUTO_FIX vs SUGGESTION test:** *"Is there anything to decide?"* No → AUTO_FIX. Yes (trade-off, preference, judgment) → SUGGESTION. When in doubt → SUGGESTION (AUTO_FIX runs without user approval).

**"Tighten / shorten comment" AUTO_FIX means REDUCE, never expand.** A comment flagged as too long or imprecise gets SHORTER, keeping only the WHY. Adding caveats or justifications is a regression of the same finding.

**Convergence = zero BLOCKERs.** AUTO_FIXes apply within the iteration and never block it.

## Persistence

Each iteration appends one entry to `metadata.code_review`:

```json
{
  "iteration": <N>,
  "blockers":   [{"id": "B-1", "text": "<finding>"}],          // iter 1
  "prior_blockers_resolved": ["B-1"],                          // iter 2+
  "prior_blockers_still_open": ["B-2"],                        // iter 2+
  "new_blockers": [{"id": "B-3", "text": "..."}],              // iter 2+
  "auto_fixes":  [{"id": "AF-1", "text": "<mechanical change>"}],
  "suggestions": [{"id": "S-1",  "text": "<observation>"}],
  "info":        [{"id": "I-1",  "text": "..."}],
  "verdict": "needs_revision | converged"
}
```

Every producing agent also appends to `metadata.changelog` (append-only, one-line items, no prose):

```json
{"stage": <N>, "iteration": <N>, "kind": "initial | fixes",
 "items": [{"type": "decision | step | fix | auto_fix", "text": "<one-line>", "blocker_id": "<when type=fix>"}]}
```

## Delegation

Heavy artifact work (writing tests/code, reviewing, fixing) goes through the Agent tool; sub-agents get isolated context windows (which makes read budgets meaningful) and enable parallelism. The orchestrator inlines every input the sub-agent needs (metadata slices, last 1-3 changelog entries, the diff); sub-agents never read sidecar files and never ask the user questions. The orchestrator itself only does state reads/writes, deterministic checks, narration, and transitions.

## Read budgets (soft caps, stated in every prompt)

| Role | Budget |
|---|---|
| Iter 1 writer | 15 source files + applicable lessons; free to grep |
| Iter 1 reviewer | The diff + last 1-2 changelog entries inline + 5 files for spot-checks |
| Iter 2+ combined fixer-reviewer | The diff + last 2 changelog entries + last code_review entry inline + 3 files tied to BLOCKER targets |
| AUTO_FIX fixer | Only the lines named in the AUTO_FIX list |

Add to every prompt: *"Read budget: N source files. If a BLOCKER genuinely requires more, note the extra reads in your changelog appendix and proceed."*

## Iteration 1 (clean slate)

1. **Writer** Agent produces the artifact, returns a changelog appendix.
2. **Reviewer** Agent returns findings JSON; orchestrator persists it to `metadata.code_review`.
3. **AUTO_FIXes**: a fixer Agent applies each mechanically ("no design changes") and returns its own appendix.
4. Zero BLOCKERs → converged: narrate `"Converged. N AUTO_FIXes applied, M SUGGESTIONs logged."` and proceed. Otherwise → iteration 2.

## Iteration 2+ (delta-aware, ONE combined Agent)

Iter 1 already had a fresh-eyes review; iter 2+ verifies targeted fixes. One combined fixer-reviewer receives inline: ac, plan, last 2 changelog entries, last code_review entry, prior BLOCKERs with IDs, and the diff. Instructions:

```
Step 1: Address each prior BLOCKER in place. Record {type: "fix", blocker_id, text}.
Step 2: Self-review: mark each prior BLOCKER RESOLVED or STILL_OPEN. Scan ONLY the lines you touched for new issues.
Step 3: Output {"changelog_appendix": {...}, "code_review_entry": {...}}  (iter 2+ shape above).
```

Remaining BLOCKERs = still_open + new. Zero → converged. Otherwise next iteration, subject to the cap. The dev can force a fresh-eyes review instead by setting `metadata.stages.3.force_fresh_review = true`.

## Max iterations without convergence

Narrate: *"The build loop did not converge after 3 iterations. <N> BLOCKERs remain: <list>. Options: 1) one more iteration, 2) accept and continue, 3) pause."* Record `loop_outcome` as `converged` or `accepted_with_residuals`; on pause, leave the stage `in_progress` for a later resume.
