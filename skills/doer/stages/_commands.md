# Doer Commands

Auxiliary commands beyond `/doer <TICKET-ID>`. `status` and `list` are read-only and skip the Workspace Guard and lock.

## `/doer status <TICKET-ID>`

Render from `metadata.json` (works for doer tickets and `bugfix.json` bug tickets alike):

```
Ticket: <TICKET-ID>, <title>
Branch: <branch>  Status: <status>
Current Stage: <N> (<name>)

Progress:
  [x] 1 ac
  [x] 2 plan
  [~] 3 build      (iteration 2/3, 1 BLOCKER open)
  [ ] 4 verify
  [ ] 5 wrapup

Blockers: <open BLOCKERs from the last code_review entry, or "none">
```

## `/doer list`

One line per directory under `./.doer/tickets/`, covering both ticket kinds (`metadata.json` → doer, `bugfix.json` → bugfix):

```
ABC-123   doer     [in_progress]  Stage 3 (build)    fix-login-timeout
PDE-2779  bugfix   [in_progress]  Stage 4 (verdict)
ABC-119   doer     [complete]                        add-redis-cache
```

Locale and Jira config are no longer doer subcommands: use `/wk:locale <code>`, `/wk:jira <url>`, or the guided `/wk:setup` instead (see their own `SKILL.md`). Doer still resolves locale at startup (`preferences.sh get-locale`), it just no longer sets it.

## `/doer cleanup-history <TICKET-ID>`

Standalone version of the wrapup's history cleanup (step 7 in `05-wrapup.md`). Use it when the cleanup was declined at wrapup, or to scrub `.doer/` from imported pre-existing commits mid-flight.

1. Read `metadata.json`; resolve branch and base. Verify the branch is checked out (ask before switching).
2. Run the Workspace Guard inline (`lib/workspace-guard.md`).
3. Run the same detection + backup-ref + `git filter-branch` sequence as wrapup step 7, with explicit dev confirmation before rewriting.
4. Safety: always narrate the backup ref (`git reset --hard <ref>` rolls back). If the branch has an upstream with commits others may have based work on (`git rev-list --count @{u}..HEAD` / `HEAD..@{u}`), warn before rewriting.
