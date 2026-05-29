# Stage 1. AC Confirm

**Goal:** produce testable ACs in `metadata.ac` + detect/import any pre-existing work.

**Stage entry runs inline; Step 6.5 (AC self-review) optionally dispatches a single sub-agent via the Agent tool when `preferences.sh get-flag stage1_ac_self_review` returns empty or `true` (default on).** No commit at end (only `.doer/` writes, which is gitignored).

**Stage 1 does NOT use `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`.** The Step 6.5 self-review is single-pass; one round, no retry on malformed output, no convergence loop.

## Step 1: Load context

1. Read `metadata.json`. Pull `title`, `intake.description`, `intake.raw_acs`, `intake.context`, and `intake.prior_work` (all captured during intake).
2. Load lessons selectively — do NOT read all lesson files unconditionally. First run:
   ```bash
   grep -l "when_it_applies" ${CLAUDE_PLUGIN_ROOT}/lessons/*.md 2>/dev/null \
     | xargs grep -l "<keyword from ticket title or type>" 2>/dev/null \
     | head -5
   ```
   Read only the files that match. If no lessons directory exists or grep returns nothing, skip silently. This replaces the prior `Read ${CLAUDE_PLUGIN_ROOT}/lessons/*.md` glob — reading all lessons unconditionally scales poorly as the global pool grows.

## Step 2: Branch on prior work (no question, read metadata)

The intake already asked "Have you done any work?" and the four follow-ups (plan, tests, code, docs). Do NOT ask again.

- `metadata.intake.prior_work.exists == false` → skip Steps 3-5. Go to Step 6 (AC confirm) with entry stage = 1.
- `metadata.intake.prior_work.exists == true` → continue to Step 3 (inspect).

## Step 3: Inspect the repo (only when prior_work.exists)

Detect base branch (prefer `main`, fall back to `master`, ask if unclear). Then:

```bash
git branch --show-current
git status --porcelain
git log --oneline <base>..HEAD
git diff <base>...HEAD     # full committed diff
git diff                    # unstaged
git diff --cached           # staged
```

For each commit ahead of base: `git show --stat <sha>` then read key files. Classify touched files:
- Tests (`*_test.*`, `*.test.*`, `tests/`, `spec/`) → user has tests
- Other code → user has implementation
- `.md`, `docs/` → user has documentation
- `PLAN.md` or `.doer/` → user has plan

If tests detected, run them via repo's test command, note pass/fail to identify red/green/broken state.

Narrate the analysis (no question, just summary, then proceed to Step 4):
```
Based on your commits:
- Plan: <yes/no + where>
- Tests: <N> files (<X pass, Y fail>)
- Implementation: <N> files (~<LOC>)
- Docs: <N> files

Summary: <one-paragraph inferred state>
```

If the inference is wrong, the dev will see it surface in the entry-stage suggestion (Step 4) and can correct there with a single decision.

## Step 4: Decide entry point

| User has... | Entry stage | Mark imported |
|-------------|-------------|---------------|
| Nothing | 1 |, |
| Plan only | 3 (tests) | 2 |
| Plan + failing tests | 4 (code) | 2, 3 |
| Plan + tests + partial code | 4 (code) | 2, 3 |
| Plan + tests + complete code | 5 (code-review) | 2, 3, 4 |

Confirm with user: *"Suggesting entry at Stage {N}, importing {list}. Proceed? [Y / start at 1 / pick stage]"*

## Step 5: Baseline + import

If there are uncommitted changes:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): import pre-existing work as baseline"
```
If there are already commits ahead of base, no extra commit needed.

Mark imported stages in `metadata.json`:
```json
"stages": {
  "2": {"name": "plan",  "status": "imported", "imported_at": "<ISO8601>", "note": "<what user had>"},
  "3": {"name": "tests", "status": "imported", "imported_at": "<ISO8601>", "note": "..."}
}
```

If a plan was imported but isn't written down, prompt the user to paste/summarize it. Either way, persist the result into `metadata.plan` using the schema documented in `${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md` (or orchestrator drafts the structured plan from the summary + diff and the user confirms). Same pattern for imported tests/code (note their file paths in `metadata.stages.<N>.imported_paths`).

## Step 6: AC draft (build only, do NOT present yet)

Build the full draft (ACs + Out of Scope + Open Questions) in memory. Do NOT present to the dev or ask any question here — Step 6.5 owns the single user-facing question.

**Branch on `metadata.testing_strategy.mode` before building the AC list:**

- **`direct`**: skip Given/When/Then restatement entirely. ACs are optional. If raw ACs from intake are empty (`raw_acs == "derive"` or empty), write a single placeholder into the draft list:
  ```
  - AC-1: DIRECT: verify <change description from intake.description, truncated to ~80 chars> renders correctly
  ```
  The `AC-N: ` prefix is mandatory so Stage 2's deterministic Check B (AC-coverage by tests) keeps working. If raw ACs DO exist, restate them as plain bullets without forcing Given/When/Then.

- **`bdd`**: restate ACs as Given/When/Then with a user or system actor (`GIVEN the user has ... WHEN they ... THEN the app ...`). Derived ACs follow the same user-centric framing. Propose 3 to 7 items.

Then in both branches:

1. Build the AC list per the branch above.
2. Build the **Out of Scope** list (items the dev should NOT confuse for in-scope).
3. Build the **Open Questions** list with proposed resolutions for each.

Hold this draft in memory and proceed immediately to Step 6.5.

## Step 6.5: AC self-review (opt-in, default on)

Run the AC self-review protocol at `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/01-ac-self-review.md` against the draft built in Step 6 BEFORE presenting anything to the dev. It owns: reading the `stage1_ac_self_review` flag, dispatching the `ac-reviewer` sub-agent (via Agent tool, single round, no loop), parsing/validating findings, promoting blockers to Open Questions, presenting the enriched block to the dev with Self-review notes, collecting the dev's single approval, incrementing `metadata.stages.1.agent_invocations`, and the non-fatal failure modes.

ONE question for the entire Stage 1 contract, asked by Step 6.5 (not Step 6). No item-by-item drilling.

**Edit/redo round limit:** after the dev approves or requests changes, accept at most **3 edit/redo rounds** (replies containing `edit ...` or `redo`). After the 3rd round, present the current block as final and proceed without asking again. Narrate: *"Accepting current block after 3 rounds. Edit metadata.ac directly if further changes are needed."* This cap prevents unbounded context growth from repeated inline re-presentations.

When the flag is `false` OR the protocol fails, Step 6.5 falls back to presenting the original Step 6 draft block (without Self-review notes) and asks the dev to approve. Step 6.5 MUST NEVER abort Stage 1.

## Step 7: Persist `metadata.ac`

Persist the confirmed Stage 1 output into `metadata.ac`:

```json
"ac": {
  "in_scope": ["AC-1: GIVEN ... WHEN ... THEN ...", "AC-2: ..."],
  "out_of_scope": ["<item>", "..."],
  "open_questions_resolved": [{"question": "<Q>", "answer": "<A>", "source": "self_review | dev"}],
  "applicable_lessons": ["<lesson-slug>", "..."],
  "self_review": {
    "ran": true,
    "iteration": 1,
    "findings": [
      {"id": "F-1", "kind": "affirmation | gap | blocker", "optional": false, "title": "<one-line>", "explain": "<one to three sentences>", "suggested_fix": "<optional on affirmation>"}
    ],
    "dev_accepted": ["F-1"],
    "dev_rejected": ["F-2"]
  }
}
```

Each `in_scope` entry is a complete Given/When/Then string starting with the AC ID. `applicable_lessons` lists slugs of global lessons (`${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md`) whose `when_it_applies` matches this ticket; downstream agents read those lesson files when relevant.

`open_questions_resolved[].source` is `"self_review"` for entries promoted by Step 6.5 from a blocker finding and `"dev"` for entries the dev wrote during Step 6. Absent field is interpreted as `"dev"` for backward compatibility with pre-6.3.0 tickets.

`self_review` is populated by Step 6.5 when the flag is on. When the flag is off OR Step 6.5 was skipped or failed, `self_review = {"ran": false, "reason": "<one-line>"}`. `dev_accepted` and `dev_rejected` reflect the dev's decision recorded at Step 6.5 step E (see Step 6.5 above for the taxonomy and persistence rules).

No sidecar `ac.md` file. No separate assumptions file (assumptions surface in Stage 2 inside `metadata.plan.assumptions`).

## Step 8: Finalize

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) before transitioning.

Update `metadata.json`: stage 1 complete, advance `current_stage` to the entry point decided in Step 5.

Narrate: *"Stage 1 complete. Imported stages: {list}. Continuing to Stage {N}..."* and immediately auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/0{N}-<name>.md` for the next stage and ONLY that file. Do NOT end the turn here.
