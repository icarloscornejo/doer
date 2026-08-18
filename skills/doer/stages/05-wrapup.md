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
printf '%s\n' "<candidate-1>" "<candidate-2>" "<candidate-3>" \
  | grep -nE '\bAC-[0-9]+\b|PROTOLOG|\bREPLAY\b|\bDOER\b|\bdoer\('
```

A match means an internal label leaked; rewrite that candidate and re-validate, never
present a matching draft. Present the three candidates in the chat as plain text, numbered
1-3, each in its own fenced code block. Drafts NEVER go inside `AskUserQuestion`, only the
selection does. Ask via `AskUserQuestion` with short labels (`Option 1` / `Option 2` /
`Option 3`), marking the strongest `(Recommended)`; the tool's auto-appended "Other" is the
edit path, and a plain-chat reply (`1`, `2`, `3`, `edit: <text>`) is equally valid. Re-run
the grep on any edited text before accepting it. Persist ONLY the chosen message to
`metadata.commit_message` via a single `metadata.sh write`.

**Squash gate, then offer to squash now** (`AskUserQuestion`: `Yes` / `No, I'll squash manually`). If this ticket ever ran `/wk:replay` or `/wk:protologs` standalone against this branch, gate on content before offering, since a legitimate `[TEMP]`/revert pair can remain in history even after a clean cleanup, so grepping commit subjects proves nothing:
```bash
git diff <base>..HEAD | grep -nE 'REPLAY START|REPLAY END|REPLAY-ORIG:|PROTOLOG_RESPONSE - |PROTOLOG - '
```
Any match: STOP, do not offer the squash, tell the dev cleanup did not fully net out and point at the offending file. Only on a clean gate (or when neither skill ever ran on this branch), proceed: on yes, skip if only 1 commit; otherwise back up (`git update-ref refs/doer-backup/<TICKET-ID>-pre-squash-$(date +%s) HEAD`), then `git reset --soft <base> && git commit --no-verify -m "<chosen message>"`, verify exactly 1 commit remains, narrate the backup ref (rollback: `git reset --hard <ref>`).

## 6. PR description

Auto-detect a template (`.github/PULL_REQUEST_TEMPLATE*`, `.gitlab/merge_request_templates/`, repo root). One found → use it; several → ask which; none → ask the dev to paste one, or reply `default` (Summary / Changes / How to test / Verification / Notes) or `skip`.

Dispatch a PR-description writer Agent (read budget 0; inline `metadata.ac`, `metadata.changelog`, `metadata.summary`, and a verification summary where every AC verdict is already translated into the behavior it describes). Rules for the output: fill every template section (`> N/A for this ticket.` where not applicable), preserve headings and directives verbatim, terse prose + bullets, no em-dashes, no internal labels (no `AC-N`, no `PROTOLOG`/`REPLAY`/`DOER`, no stage names, no literal `doer`). Validate with the same grep as step 5 before presenting; scrub or regenerate on a match. Present wrapped in a four-backtick fence (four backticks on their own line before and after) so the description's own markdown, including any triple-backtick blocks inside it (e.g. a "How to test" snippet), renders literally in chat and copies verbatim. Then ask a plain-chat question ("keep it as is, or want changes?") and **end the turn there** (`lib/narration.md` turn boundary 4); never `AskUserQuestion` for this. Persisting `metadata.pr_description` before the dev's reply is prohibited. On requested changes, rewrite, re-validate with the same grep, re-present, and ask again, as many rounds as needed. Only an explicit ok (or `skip`) unlocks persisting: on ok, `metadata.sh write` the approved text to `metadata.pr_description`; on `skip`, persist the literal `"skipped"` the same way.

## 7. History cleanup

```bash
git log --format=%H --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"
```

Empty (the normal case with the Workspace Guard active from intake) → skip. Otherwise confirm with the dev (destructive, rewrites SHAs), then:

```bash
git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
git update-ref -d "refs/original/refs/heads/<branch>" 2>/dev/null || true
```

Verify the log is now empty; narrate the backup ref. Files on disk are never touched, only history.

## 8. Close

Precondition: step 6 has the dev's explicit approval of the PR description (or `"skipped"`); if not, this step does not run. Release the lock (`rm -f ./.doer/tickets/<TICKET-ID>/lock.json`) and the session marker (`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" stop`). Self-check: `metadata.commit_message` and `metadata.pr_description` are non-null (or `"skipped"`); if either is missing, jump back to that step now, before any closing narration. Validate required fields per `lib/state.md`. Build ONE jq filter that in a single pass sets `metadata.summary`, `metadata.status = "complete"`, `metadata.completed_at` (all held from step 4), and `stages.5` complete (`completed_at`); call `metadata.sh write` exactly once.

Closing narration (in the operating locale): render `metadata.summary`, then: *"Ticket <TICKET-ID> complete. <N> commit(s) on `<branch>`. Run your pre-commit checks, use the commit message and PR description above, then push and open the PR manually (or keep everything as is)."*
