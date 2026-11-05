# Stage 5. Wrapup

**Goal:** validate assumptions, capture lessons, check docs, deliver commit message + PR description, clean `.doer/` from branch history, close the ticket. Steps run in this order; 5 and 6 are the two the dev came for and are NEVER skipped silently (the dev may decline 6 with `skip`, which is recorded).

## 1. Validate assumptions

For each `metadata.plan.assumptions` entry, mark `VALIDATED`, `INVALIDATED` (with a one-line reason), or `UNVERIFIED` based on what Stages 3-4 showed. Hold the result as `metadata.assumptions_validation` (persisted together with `lessons_captured` in step 2, one `metadata.sh write`).

## 2. Capture lessons

Scan the ticket for lesson signals before asking: the loop hit max iterations or needed 3; Stage 4 returned `RETURN_TO_BUILD`; an assumption was INVALIDATED; a security or data-integrity BLOCKER appeared late. Present any candidates (accept by number, `add: <lesson>`, `edit N: <text>`, or `none`); with no signals, ask once: *"Any lesson worth saving for future tickets? Reply with one, or `none`."*

Write each accepted lesson to the GLOBAL pool `${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md` (English, cross-project):

```markdown
---
slug: <kebab-case>
captured_from: <TICKET-ID>
captured_at: <ISO8601>
skill_version: <this SKILL.md's frontmatter version at capture time, e.g. "7.2.5">
when_it_applies: <short context>
---
## What happened
## Why it matters
## Takeaway
```

Reference them in `metadata.lessons_captured` (`[{slug, takeaway}]`). Drafting reads only metadata and `git log/diff`, never the codebase.

Persist steps 1 and 2 together in ONE `metadata.sh write`: `metadata.assumptions_validation` and `metadata.lessons_captured`.

## 3. Docs check (lightweight)

Grep README/CHANGELOG/docs for identifiers the diff removed or renamed, and note any new public surface (exports, CLI flags, routes, env vars) with no doc mention. Nothing found → narrate one line and move on. Something found → propose the specific edits, apply on approval, commit:

```bash
git add -A && git commit --no-verify -m "doer(<TICKET-ID>): sync documentation"
```

## 4. Summary

Draft `metadata.summary`: one paragraph in English (what was delivered, what actually changed, notable surprises). Hold it along with `metadata.status = "complete"` and `metadata.completed_at` for step 8's single write; do not persist yet (steps 5-7 still need to happen first).

## 5. Recommended commit message

The dev squashes the per-stage commits into one PR-ready commit. Draft THREE candidates,
each `<TICKET-ID>: <Subject ≤72 chars>` with the subject starting uppercase, specific to the actual change, in plain business
language. Each candidate takes a genuinely different angle (the user-visible behavior, the
component changed, the problem solved), not rewordings of the same sentence. Validate all
three before presenting (Core Principle 10):

```bash
printf '%s\n' "<candidate-1>" "<candidate-2>" "<candidate-3>" | "${CLAUDE_PLUGIN_ROOT}/lib/helpers/vocab-guard.sh"
```

A match means an internal label leaked; rewrite that candidate and re-validate, never
present a matching draft. Present the three candidates in the chat as plain text, numbered
1-3, each in its own fenced code block. Drafts NEVER go inside `AskUserQuestion`, only the
selection does. Ask via `AskUserQuestion` with short labels (`Option 1` / `Option 2` /
`Option 3`), marking the strongest `(Recommended)`; the tool's auto-appended "Other" is the
edit path, and a plain-chat reply (`1`, `2`, `3`, `edit: <text>`) is equally valid. Re-run
`vocab-guard.sh` on any edited text before accepting it. Persist ONLY the chosen message to
`metadata.commit_message` via a single `metadata.sh write`.

**Squash gate, then offer to squash now** (`AskUserQuestion`: `Yes` / `No, I'll squash manually`). If this ticket ever ran `/wk:replay` or `/wk:protologs` standalone against this branch, gate on content before offering, since a legitimate `[TEMP]`/revert pair can remain in history even after a clean cleanup, so grepping commit subjects proves nothing. Run the squash gate as its own Bash command, never chained with the squash or any other step (`&&`, `;`, `||` or a pipe): its exit code is the decision.
```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-checks.sh" squash-gate <base>
```
Exit 1 or 2: STOP. Do not squash and do not offer the squash. Report the printed lines to the dev (and to the orchestrator when one is driving), even when the match looks like a false positive; only the dev decides what happens next. Exit 1 means a marker was added by the branch (the printed lines name the file); exit 2 means the base is unusable or git failed. A repo that documents or tests the markers (this kit does) lists the paths where that text is legitimate in `.doer-gate-ignore` at its base branch; the gate skips only those paths and still fails on a marker anywhere else. Only on a clean gate (exit 0, or when neither skill ever ran on this branch), proceed in a separate command: on yes,
```bash
printf '%s' "<chosen message>" | "${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-ops.sh" squash <base> <TICKET-ID> doer
```
prints `SKIP: 1 commit` (nothing to do) or `BACKUP <ref>` followed by the squash itself (backup ref, `reset --soft`, commit, verify exactly 1 commit remains, all atomic); narrate the backup ref (rollback: `git reset --hard <ref>`). Exit 1 means it refused for a stated reason (dirty tree, base not an ancestor) and changed nothing; exit 2 after a `BACKUP <ref>` line means a git step failed after the backup, so narrate the ref and the rollback and stop. Never append a `Co-Authored-By` trailer to any candidate; `git-ops.sh squash` strips one and prints `STRIPPED Co-Authored-By trailer`, and exits 1 if a repo-side git hook re-injects it.

## 6. PR description

Auto-detect a template:
```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-checks.sh" pr-templates
```
One found → use it; several → ask which; none → ask the dev to paste one, or reply `default` (Summary / Changes / How to test / Verification / Notes) or `skip`.

Dispatch a PR-description writer Agent with `model: "haiku"` on every dispatch of this writer, rewrite rounds included (it only turns inlined text into text: it writes no code and judges none; every other dispatch inherits the session model). If the whole inlined prompt would pass 100 KB (about 33k tokens of ordinary prose, which with the roughly 38k fixed tokens of any subagent stays under the 100k-token long-prompt threshold), omit `model` and never trim the input. (Read budget 0; inline a user-facing AC projection, `{"in_scope": metadata.ac.in_scope, "out_of_scope": metadata.ac.out_of_scope.map(text)}`, never the full `metadata.ac` object, plus `metadata.changelog`, `metadata.summary`, and a verification summary where every AC verdict is already translated into the behavior it describes). The projection deliberately excludes `candidates`, `merged`, `source_map`, `discarded_intake_items`, and `self_review`: none of Stage 1's internal provenance belongs in a PR description, and every one of those fields can carry an `O-`/`C-`/`OOS-`/`Q-`/`R<n>-F<m>` identifier. Rules for the output: fill every template section (`> N/A for this ticket.` where not applicable), preserve headings and directives verbatim, terse prose + bullets, no em-dashes, no internal labels (no `AC-N` or any of Stage 1's other internal ID families `O-`/`C-`/`OOS-`/`Q-`/`R<n>-F<m>`, no `PROTOLOG`/`REPLAY`/`DOER`, no stage names, no literal `doer`). Validate with `vocab-guard.sh` (same as step 5) before presenting; scrub or regenerate on a match. Present wrapped in a four-backtick fence (four backticks on their own line before and after) so the description's own markdown, including any triple-backtick blocks inside it (e.g. a "How to test" snippet), renders literally in chat and copies verbatim. Then ask a plain-chat question ("keep it as is, or want changes?") and **end the turn there** (`lib/narration.md` turn boundary 4); never `AskUserQuestion` for this. Persisting `metadata.pr_description` before the dev's reply is prohibited. On requested changes, rewrite, re-validate with `vocab-guard.sh`, re-present, and ask again, as many rounds as needed. Only an explicit ok (or `skip`) unlocks persisting: on ok, `metadata.sh write` the approved text to `metadata.pr_description`; on `skip`, persist the literal `"skipped"` the same way.

## 7. History cleanup

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-checks.sh" doer-history <base>
```

Exit 2 means the base is unusable or git failed: stop and report it, never read it as an empty or clean result. Empty (the normal case with the Workspace Guard active from intake) → skip. Otherwise confirm with the dev (destructive, rewrites SHAs), then:

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-ops.sh" scrub-history <base> <TICKET-ID> doer
```

Prints `BACKUP <ref>` before rewriting anything, then backs up, runs `filter-branch` scoped to `<base>..HEAD` only, drops `refs/original/refs/heads/<branch>`, and verifies the log is now empty. Files on disk are never touched, only history. Read the exit code with the output: exit 1 with no BACKUP line means the working tree is dirty and `scrub-history` refused before touching anything (there is nothing to roll back and no reset is to be offered: ask the dev to commit or stash, then run it again); exit 1 after a `BACKUP <ref>` line means `.doer/` somehow survived the rewrite, so narrate the backup ref (rollback: `git reset --hard <ref>`); exit 2 after a `BACKUP <ref>` line means a git step failed mid-rewrite, so narrate the ref and the rollback and stop.

## 8. Close

Precondition: step 6 has the dev's explicit approval of the PR description (or `"skipped"`); if not, this step does not run. Release the lock and the session marker: `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/workspace-guard.sh" release "<TICKET-ID>"`. Self-check: `metadata.commit_message` and `metadata.pr_description` are non-null (or `"skipped"`); if either is missing, jump back to that step now, before any closing narration. Record the cost first: `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh" record "<TICKET-ID>" > .doer/tickets/<TICKET-ID>/cost-record.json` (prints one JSON object, never fails). If that output is empty or not a JSON object, use `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh" unknown "<reason>"` instead, so a close is never blocked by cost. Build ONE jq filter that in a single pass sets `metadata.summary`, `metadata.status = "complete"`, `metadata.completed_at` (all held from step 4), `.cost = $cost[0]` and `stages.5` complete (`completed_at`); call `metadata.sh write "<TICKET-ID>" '<filter>' --slurpfile cost .doer/tickets/<TICKET-ID>/cost-record.json --require 5:complete` exactly once, then delete `cost-record.json` after the successful write. `--require` validates the required fields per `lib/state.md` against the transformed document before swapping; on failure, back-fill and write again as a NEW transition.

Closing narration (in the operating locale): render `metadata.summary`, then: *"Ticket <TICKET-ID> complete. <N> commit(s) on `<branch>`. Run your pre-commit checks, use the commit message and PR description above, then push and open the PR manually (or keep everything as is)."*
