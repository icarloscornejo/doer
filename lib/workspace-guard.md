# Workspace Guard + Per-Ticket Lock

Idempotent check that prevents `.doer/` (including `.doer/config.json`, the per-project Jira config) from ever being committed in this clone, plus a lightweight lock against two sessions racing on the same ticket. A dead session's lock (recorded process gone, same host) is stolen immediately; a live one blocks for up to 30 minutes. MUST run at every ticket-scoped entry point: intake (after creating the branch), resume, `cleanup-history`. `/wk:setup` and `/wk:jira <url>` also run steps 1-3 (the exclude rule) before writing `config.json`; they skip step 4, the per-ticket lock, since they are not ticket-scoped.

Implemented by `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/workspace-guard.sh"`:

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/workspace-guard.sh" acquire <TICKET-ID> <doer|bugfix>
```

for ticket-scoped entry points, or

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/workspace-guard.sh" acquire --no-lock
```

for `/wk:setup` and `/wk:jira <url>` (steps 1-3 only, no lock, no session marker). Release with

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/workspace-guard.sh" release <TICKET-ID>
```

at wrapup (or let a crashed session's lock age out after 30 minutes; the session marker is likewise inert on a crash, pruned on the next `start`).

**MUST be invoked as the Bash tool's entire command**: a bare statement, never wrapped in `$(...)`, a subshell, or chained after another command with `&&`. `$PPID` must stay the long-lived claude process for this session, the same invariant `lib/helpers/session.sh` itself depends on (`acquire`/`release` `exec` into `session.sh` at the end specifically so it inherits that exact `$PPID`, not workspace-guard.sh's own pid as its parent).

`acquire` does, in order: (1) ensure the exclude rule exists in `.git/info/exclude` (per-clone, never committed; team sees nothing), (2) verify it actually takes effect, refusing (exit 1) if some override (a global gitignore, say) makes it not, (3) detect any already-tracked `.doer/` files, (4) the per-ticket lock (steal a dead or stale one, refresh a same-session one, block on a live different one), (5) the session marker (`session.sh start doer` or `start bugfix`, matching the invoking skill), activating this plugin's PreToolUse guards (`git-commit-no-verify-guard.sh`, the protolog guards, the replay guards) for this session only; a normal Claude Code session with the plugin installed but no wk skill active stays unaffected by them.

- Output: a `TRACKED <path>` line (one file, exit 0) when `.doer/` has already-tracked content; ask the user once per ticket: 1) commit `git rm -r --cached .doer/` on this branch, 2) skip and clean manually later, 3) untrack silently (stage but do not commit). Default 3. Nothing printed when the tree is clean.
- A `LOCKED: ...` line with exit 1 means another live session holds the lock: stop the run and surface the message verbatim. No retry, no prompt, and NEVER delete or rewrite `lock.json` manually to bypass it: the liveness check already steals every objectively dead lock, so a surviving `LOCKED` means the other session is (or may be) alive, even if the dev believes otherwise. The user closes the other session and re-invokes; the steal then happens on its own.
- For scrubbing historical `.doer/` content from earlier commits, use `/doer cleanup-history <TICKET-ID>` (out of scope for the Guard).
