# Doer Commands

Auxiliary commands beyond `/doer <TICKET-ID>`. `status` and `list` are read-only and skip the Workspace Guard and lock.

## `/doer status <TICKET-ID>`

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" status <TICKET-ID>
```

Renders from `metadata.json` or `bugfix.json`, whichever exists for this ticket (auto-detected):

```
Ticket: <TICKET-ID>, <title>
Branch: <branch>  Status: <status>
Current Stage: <N> (<name>)

Progress:
  [x] 1 ac
  [x] 2 plan
  [~] 3 build
  [ ] 4 verify
  [ ] 5 wrapup

Blockers: <open BLOCKERs from the last code_review entry, or "none">
```

When the ticket has a `cost` record, a `Cost:` line closes the output: `Cost: $17.62 across 3 sessions (whole sessions)`, or `Cost: unknown (<first reason>)`. A key holding both files prints one `Cost:` line per file.

When Stage 4 is complete, a `Verify evidence:` block follows: per AC its verdict and evidence, then anomalies, rationale, and any `accepted_not_exercised` reasons (`(none recorded)` for tickets completed before 7.11.0).

## `/doer list`

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" list
```

One line per directory under `./.doer/tickets/`, covering both ticket kinds (`metadata.json` → doer, `bugfix.json` → bugfix):

```
ABC-123   doer     [in_progress]  Stage 3 (build)    fix-login-timeout
PDE-2779  bugfix   [in_progress]  Stage 4 (verdict)
ABC-119   doer     [complete]                        add-redis-cache    Cost: $4.10 across 2 sessions (whole sessions)
```

The cost is appended only to tickets that have a `cost` record.

Locale and Jira config are no longer doer subcommands: use `/wk:locale <code>`, `/wk:jira <url>`, or the guided `/wk:setup` instead (see their own `SKILL.md`). Doer still resolves locale at startup (`preferences.sh get-locale`), it just no longer sets it.

## `/doer cleanup-history <TICKET-ID>`

Standalone version of the wrapup's history cleanup (step 7 in `05-wrapup.md`). Use it when the cleanup was declined at wrapup, or to scrub `.doer/` from imported pre-existing commits mid-flight.

1. Read `metadata.json`; resolve branch and base. Verify the branch is checked out (ask before switching).
2. Run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/workspace-guard.sh" acquire "<TICKET-ID>" doer` (contract: `lib/workspace-guard.md`).
3. Run the same detection + rewrite as wrapup step 7 (`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-checks.sh" doer-history <base>`, then `git-ops.sh scrub-history <base> <TICKET-ID> doer` on confirmation), with explicit dev confirmation before rewriting. Exit 2 means the base is unusable or git failed: stop and report it, never read it as an empty or clean result.
4. Safety: always narrate the backup ref (`git reset --hard <ref>` rolls back). If the branch has an upstream with commits others may have based work on (`git rev-list --count @{u}..HEAD` / `HEAD..@{u}`), warn before rewriting.
