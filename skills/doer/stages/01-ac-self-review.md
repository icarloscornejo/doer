# Stage 1 - Step 6.5: AC self-review (opt-in, default on)

**Goal:** confront the draft built in Step 6 against the original intake (`description`, `raw_acs`, `context`) and surface affirmations, gaps, and blockers BEFORE the dev sees the block. Step 6.5 is the ONLY place where the block is presented to the dev and the single approval question is asked. Step 6 builds the draft silently; Step 6.5 enriches it with Self-review notes (and promotes blocker findings into Open Questions) before showing it.

**Step 6.5 MUST NEVER abort Stage 1.** Single round, no loop, no retry on malformed output. See Failure modes at the bottom.

## A. Read the flag

Run `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh get-flag stage1_ac_self_review`. The helper emits `"true"`, `"false"`, or empty (unset). Treat empty as `"true"` (the default in `ensure_file()` is `true`; pre-existing preferences files written before 6.3.0 will return empty and SHOULD opt in by default).
- Output `"false"` → skip to the **Fallback path** at the bottom of this file (present the Step 6 draft without Self-review notes and collect the single dev approval), set `metadata.ac.self_review = {"ran": false, "reason": "flag disabled"}`, then proceed to Step 7.
- Empty or `"true"` → continue to B.

## B. Dispatch the `ac-reviewer` sub-agent

MUST invoke via the Agent tool. The orchestrator MUST NOT inline this work. Single round, no loop, no retry on malformed output.

**Doer agent:** general-purpose, prompted as "AC reviewer". Read budget: 0 source files (all context is inlined; the reviewer never opens the repo).

### AC reviewer prompt (skeleton)

```
You are the AC reviewer for ticket <TICKET-ID>.

The orchestrator has inlined every input you need below. Do NOT read source files;
you have a read budget of 0. Em-dashes are forbidden in your output.

== metadata.intake ==
<JSON dump of metadata.intake: description, raw_acs, context, prior_work>

== metadata.testing_strategy ==
<JSON dump of metadata.testing_strategy: mode, rationale, signals>

== Draft built in Step 6 ==
{
  "in_scope":            ["AC-1: ...", "AC-2: ..."],
  "out_of_scope":        ["..."],
  "open_questions_resolved": [{"question": "...", "answer": "..."}]
}

== Applicable lessons (read inline if relevant; full text dumped here) ==
<for each slug in metadata.ac.applicable_lessons, the file body of
${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md>

Your job: compare the draft against intake.description and intake.raw_acs and
emit findings under a fixed three-tier taxonomy.

Taxonomy (fixed; do not invent new kinds):
- "affirmation": specific things in the draft that match the description well.
  MANDATORY: emit at least one affirmation per AC ID present in `in_scope`.
  This is non-negotiable. A reviewer that emits only negatives erodes dev trust.
- "gap": something the description mentions or implies that the draft handles
  imprecisely or omits. Set `optional: true` when the gap is a granularity or
  preference matter (e.g. "AC-5 mixes two scenarios; could be split"); set
  `optional: false` when the gap is structural (e.g. "description requires X,
  no AC covers it").
- "blocker": a DIRECT contradiction between the draft and intake.description.
  Use sparingly. Promotion to Open Questions is automatic; suggested_fix MUST
  be phrased as a concrete proposed resolution to that question.

Output exactly this JSON object, no prose, no code fences:

{
  "findings": [
    {
      "id": "F-1",
      "kind": "affirmation | gap | blocker",
      "optional": false,
      "title": "<one-line, <=80 chars>",
      "explain": "<one to three sentences; cite which AC or which part of the
                 description; no em-dashes>",
      "suggested_fix": "<one to three sentences; for blocker, phrase as a
                       proposed resolution; may be omitted on affirmation>"
    }
  ]
}

Constraints:
- IDs are contiguous F-N, starting at F-1.
- `optional` is required on every entry; affirmations and blockers MUST set it
  to false.
- Total findings <= 12. Prioritize signal over volume.
- If the draft is genuinely solid and you cannot find any gap or blocker,
  return only affirmations. Do NOT manufacture findings.
- Do NOT propose changes to `out_of_scope` items unless the description
  contradicts the exclusion.
- Do NOT re-judge `open_questions_resolved` entries that already exist; the
  dev resolved those upstream. You may add new Open Questions only by emitting
  a `blocker` finding.
```

## C. Parse the findings JSON

Validate the shape:
- top-level object with a `findings` array (may be empty)
- each entry has `id` (`F-N`, contiguous), `kind` ∈ {`affirmation`, `gap`, `blocker`}, `optional` (bool), `title`, `explain`
- `suggested_fix` is required on `gap` and `blocker`, optional on `affirmation`

If any invariant fails, treat as malformed (see Failure modes below).

## D. Promote blockers into Open Questions

For each finding with `kind: "blocker"`, append to the draft's `open_questions_resolved` list:
```json
{
  "question": "<finding.title>: <finding.explain>",
  "answer":   "<finding.suggested_fix>",
  "source":   "self_review"
}
```
The dev's existing Open Questions retain `source: "dev"` (or absent, interpreted as `"dev"` for backward compatibility with pre-6.3.0 tickets). Do NOT silently rewrite an existing question; if a blocker collides with an existing question, log it as a separate Open Question with the `self_review` source.

## E. Re-present the Stage 1 block to the dev

This REPLACES the Step 6 single question; do NOT ask twice. Show:

```
Draft for Stage 1 (testing strategy: <DIRECT | BDD>):

## Acceptance Criteria
- AC-1: ...
- AC-2: ...

## Out of Scope
- ...

## Open Questions (proposed resolutions)
- Q: <existing dev Q> -> A: <existing dev A>
- Q: <promoted blocker Q> -> A: <promoted blocker A>   [self-review]

## Self-review notes
Affirmations:
- F-1: <title>
- F-2: <title>
Gaps:
- F-3: <title>   [structural]
- F-4: <title>   [optional]
Blockers (already promoted to Open Questions above):
- F-5 -> Q above

Approve the whole block, or tell me what to edit.
[Y / edit <section>:<change> / drop <F-id>[,<F-id>...] / redo]
```

The `drop <F-id>` action is new in 6.3.0: it removes a promoted blocker from `open_questions_resolved` and records the finding under `dev_rejected` for the persistence step. Edits to AC text and Out of Scope continue to use the existing `edit <section>:<change>` syntax.

Iteration rules (mirror Step 6):
- `Y` → accept the block as shown; record every promoted blocker as `dev_accepted` and every shown gap/affirmation that the dev did NOT explicitly drop as `dev_accepted`. Proceed to Step 7.
- `edit ...` → apply edits, re-present the same block (findings are NOT re-generated; the original findings list stays visible until approval).
- `drop F-N[,F-M]` → remove promoted entries, record those ids in `dev_rejected`, re-present.
- `redo` → start over from Step 6 item 1; Step 6.5 will run again on the fresh draft.

## F. Increment the agent counter

Set `metadata.stages.1.agent_invocations = (metadata.stages.1.agent_invocations | 0) + 1`. The Stage Finalization Checklist still treats this field as optional for Stage 1, so when the flag is `false` no increment occurs and existing tickets without the field stay unchanged.

## F.1. Cost attribution (Agent `description` convention)

Cost is recovered from the session transcript at Stage 9 (`cost-transcript.sh reconcile`), not from the Agent return (the Claude Code Agent tool does not expose token counts in its `tool_result`). To make the per-stage / per-agent breakdown attributable, the orchestrator MUST set the `description` of the ac-reviewer Agent to the canonical prefix when dispatching it:

```
doer:s1:ac-reviewer | <free text describing the call>
```

The reconciler parses `doer:s<N>:<role>` from each sub-agent's sibling `meta.json` to build `cost.by_stage` and `cost.by_agent`. Without the prefix the call still counts toward totals but lands under `unassigned`. See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md`.

## Failure modes (all non-fatal)

Step 6.5 MUST NEVER abort Stage 1.
- Agent tool error or timeout → narrate one warning (`"AC self-review skipped: <reason>"`), set `metadata.ac.self_review = {"ran": false, "reason": "<reason>"}`, fall through to the **Fallback path** below.
- Malformed JSON / shape violation → same as above with `reason: "malformed output"`.
- Empty `findings` array (zero items) → treat as a successful run with no findings; present the standard block plus a Self-review notes section reading `(no findings)`. Persist `metadata.ac.self_review = {"ran": true, "iteration": 1, "findings": [], "dev_accepted": [], "dev_rejected": []}`.

## Fallback path (flag disabled or failure)

Present the Step 6 draft as-is (no Self-review notes section) and ask the ONE approval question:

```
Draft for Stage 1 (testing strategy: <DIRECT | BDD>):

## Acceptance Criteria
- AC-1: <branch-appropriate format>
- AC-2: ...

## Out of Scope
- <item 1>

## Open Questions (proposed resolutions)
- Q: <question> -> A: <proposed answer>

Approve the whole block, or tell me what to edit. [Y / edit <section>:<change> / redo]
```

Iteration rules:
- `Y` → proceed to Step 7.
- `edit ...` → apply edits, re-present.
- `redo` → start over from Step 6 item 1 in `01-ac-confirm.md`.
