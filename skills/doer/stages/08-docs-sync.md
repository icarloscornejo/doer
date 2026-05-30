# Stage 8. Docs Sync

**Goal:** update user-facing documentation when the change actually affects it. Skip aggressively when it doesn't. The doc updater never freelances; it gets an exact list of what to update.

## Pre-check A: classify ticket (should docs even run?)

Auto-skip Stage 8 entirely when the ticket clearly does NOT affect user-facing docs. Heuristics:

- Title or description mentions: `fix bug`, `bug`, `internal`, `refactor`, `rename`, `cleanup`, `chore`, `revert`, `typo`, `comment`, `test only`, `restructure`.
- Diff touches ONLY paths classified as internal: `internal/`, `private/`, `*Test.*`, `__tests__/`, `spec/`, `.github/`, `docs/.doer-internal/`, build/CI config.
- Diff does NOT add or modify any public surface (no new exports, no new public functions, no new CLI flags, no new HTTP endpoints, no new env vars).

If ALL three signals point to "no public-facing change" → skip silently:
```
metadata.stages.8.status = "skipped"
metadata.stages.8.skipped_reason = "no public-facing change in this ticket"
narrate: "Stage 8 skipped: ticket is internal/refactor only, no doc updates needed."
```
Run the Stage Finalization Checklist and proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/09-wrapup.md` and ONLY that file.

## Pre-check B: grep for stale references

If we did NOT skip in A, scan docs for references to identifiers the ticket REMOVED or RENAMED. This catches docs that point to functions or classes that no longer exist.

```bash
# Identifiers that disappeared from the diff:
REMOVED=$(git diff <base>..HEAD | grep -E '^-' | grep -oE '\b(fun|def|function|class|interface|object|public|export|const|let)\s+\w+' | awk '{print $NF}' | sort -u)

# Identifiers that appeared (potential renames target):
ADDED=$(git diff <base>..HEAD | grep -E '^\+' | grep -oE '\b(fun|def|function|class|interface|object|public|export|const|let)\s+\w+' | awk '{print $NF}' | sort -u)

# Doc files to scan:
DOC_FILES=$(find . -type f \( -name 'README*' -o -name 'CHANGELOG*' -o -path '*/docs/*' -o -path '*/documentation/*' \) ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.doer/*')
```

**N×M cap:** before running the grep loop, count `N_IDENTS=$(echo "$REMOVED" | wc -w)` and `N_DOCS=$(echo "$DOC_FILES" | wc -l)`. If `N_IDENTS * N_DOCS > 20`, sample instead of full sweep: take the top 4 identifiers by length (longer names are more specific and less likely to false-positive) and the top 5 doc files by recency (`git log --name-only`). Narrate the cap: *"Pre-check B: N×M = <product> exceeds threshold. Sampling top 4 identifiers × top 5 doc files."* This prevents dozens of inline Bash calls on large repos.

```bash
# For each removed identifier, grep doc files:
for ident in $REMOVED; do
  for doc in $DOC_FILES; do
    grep -nH "\b${ident}\b" "$doc" 2>/dev/null
  done
done
```

Each match is a "stale reference" → BLOCKER if the identifier is gone (not renamed); AUTO_FIX if a clear rename target exists in `ADDED`.

## Pre-check C: detect new public surface

Scan the diff for newly added public API:
- New `export` / `public function` / `public class`
- New CLI flag definitions (look for argparse / clap / cobra / yargs patterns by file)
- New HTTP route definitions (look for `@Get`, `@Post`, `app.get(`, `router.get(`, etc.)
- New env vars referenced (`process.env.X`, `os.getenv("X")`, `System.getenv("X")`)

Build a list of NEW public surface items. Each one is a candidate for a new entry in README/CHANGELOG/docs.

## Build the exact update list

Combine A's candidate doc files (the ones that exist in the repo) with B's stale references and C's new public surface, into a structured list:

```
Update list for docs-updater:

Stale references (BLOCKER unless rename):
- README.md:42 mentions removed function `oldLogin()` (no rename target detected)
- docs/api.md:18 mentions removed class `LegacyAuth` (rename target: `AuthV2`?)

New public surface to document:
- New CLI flag `--retry-count` added in src/cli.ts
- New public function `validateOtpEmail` in src/auth.ts

Doc files to potentially update:
- README.md (mentions are above)
- CHANGELOG.md (always candidate when public surface added)
- docs/api.md (mentions stale identifier)
```

If the update list is EMPTY (no stale references AND no new public surface), skip Stage 8 silently:
```
metadata.stages.8.status = "skipped"
metadata.stages.8.skipped_reason = "no stale doc references, no new public surface"
```
Run the Stage Finalization Checklist and proceed to Stage 9.

## Invoke docs-updater (only if there is an explicit list)

The orchestrator MUST invoke a docs-updater sub-agent via the Agent tool. The orchestrator MUST NOT update the documentation inline.

```
You are the docs-updater agent for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Last 2 metadata.changelog entries ==
<JSON dump>

== Diff ==
<output of `git diff <base>..HEAD`>

Update list (this is your ENTIRE scope, do not freelance beyond it):
<paste the structured list from the pre-check>

Read budget: ONLY the doc files named in the update list above. 0 source
files (the diff is already inlined; pre-checks already validated stale refs
and new public surface). If you feel you need to read a source file to apply
a doc edit, that is a sign the pre-check missed something; flag it in the
output instead of exploring.

For each stale reference: rename if a clear target exists, otherwise
remove or rewrite that mention to reflect what now exists.

For each new public surface item: add the appropriate entry in
README/CHANGELOG/docs as called out by the list. Match the existing
style of those files.

Rules:
- Do NOT touch sections of doc files that are not in the update list.
- Do NOT introduce marketing language or superlatives.
- Do NOT add em-dashes.
- Keep changes minimal and factual.

Output JSON: {"changelog_appendix": {"stage": 8, "iteration": 1, "kind": "initial",
"items": [{"type": "step", "text": "<one-line summary of doc edit>"}, ...]}}.
```

## Cost attribution (Agent `description` convention)

Cost is recovered from the session transcript at Stage 9 (`cost-transcript.sh reconcile`), not from the Agent return. To make the per-stage / per-agent breakdown attributable, set the `description` of the docs-updater Agent to the canonical prefix when dispatching it:

```
doer:s8:docs-writer | <free text describing the call>
```

Increment `metadata.stages.8.agent_invocations` after the docs-updater return. The reconciler parses `doer:s<N>:<role>` from each sub-agent's `meta.json` to build `cost.by_stage` / `cost.by_agent`; without the prefix the call lands under `unassigned`. See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md`.

## Commit

```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): sync documentation"
```

If the docs-updater produced no diff (rare; the list was non-empty but the agent declined to change anything), narrate that and skip the commit.

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) before transitioning. Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/09-wrapup.md` and ONLY that file.
