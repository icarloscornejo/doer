# Lock Protocol

Status: protocol shared by all skills in the `wk` plugin. Implemented in `WK-1` (shipped in v6.0.0).

Per-ticket exclusive lock that prevents two concurrent `/wk:doer` sessions from racing on the same ticket. Single-user, single-machine guarantee. Cross-host concurrency is out of scope (`.doer/` is per-clone, not shared).

## Lock file

Location: `./.doer/tickets/<TICKET-ID>/lock.json` (next to `metadata.json`, per-ticket).

Shape:

```json
{
  "ticket_id": "<ID>",
  "pid": 12345,
  "host": "<hostname>",
  "acquired_at": "<ISO8601>",
  "last_touched_at": "<ISO8601>",
  "session_label": "claude-code"
}
```

- `pid` is a diagnostic for the human (so they know which terminal to close), not load-bearing for liveness checks.
- `acquired_at` never changes after acquire. `last_touched_at` is heartbeat-updated on every stage transition.
- `session_label` is freeform; defaults to `claude-code`.

## Staleness

A lock is **stale** when `now - last_touched_at >= LOCK_TTL_SECONDS` (default `1800`, 30 minutes). Stale locks are auto-stolen on the next `acquire`. Rationale: Claude Code shells are not stable across tool calls, so PID-based liveness (`kill -0`) is unreliable for liveness; timestamp-TTL is the canonical signal.

## Operations

The orchestrator MUST call these via `${CLAUDE_PLUGIN_ROOT}/lib/helpers/lock.sh`:

| Operation | When | Behavior |
|-----------|------|----------|
| `acquire <ID>` | Workspace Guard step (every entry point) | Writes lock if absent. If present and fresh: print error + exit 1. If present and stale: steal (overwrite) + narrate. |
| `touch <ID>` | Every stage transition (after metadata write) | Updates `last_touched_at`. No-op if lock missing. |
| `release <ID>` | Stage 9 wrapup (terminal) | Removes lock. No-op if already absent. |
| `check <ID>` | `/wk:doer status <ID>` | Prints lock state: `held|stale|none` plus PID/host for diagnostics. |

## Acquire flow

1. If `lock.json` does not exist: write new lock, narrate `"Lock acquired for <ID> (PID <pid>)."`, return 0.
2. Read existing lock. If `now - last_touched_at > LOCK_TTL_SECONDS`: steal (overwrite), narrate `"Stale lock from PID <old> reclaimed (last touched <Xm ago>)."`, return 0.
3. Otherwise: print to stderr the PID, host, and `last_touched_at`, narrate `"Ticket <ID> is locked by PID <pid> on <host> (last touched <ts>). Close that session or wait for the lock to expire."`, return 1.

The orchestrator MUST stop the run on a non-zero return from `acquire`. No retry, no AskUserQuestion. The user resolves the conflict manually (close the other session, kill the process, or wait).

## Release flow

Stage 9 wrapup calls `release <ID>` after marking the ticket complete. If the orchestrator crashes mid-pipeline, the lock survives until `last_touched_at` ages out (30 min default). That is acceptable: the next `/wk:doer <ID>` invocation will steal it transparently.

## Touch cadence

Every stage transition (where the orchestrator writes `metadata.stages.<N>.completed_at`), it MUST also call `touch <ID>`. Cost: one bash call per stage boundary. Skipping touches will not break correctness but will let the lock age into "stale" sooner than expected, allowing a parallel session to steal it.

## Configuration

`LOCK_TTL_SECONDS` defaults to `1800` (30 minutes). Override per-invocation with the env var `WK_LOCK_TTL_SECONDS=<n>`. There is no global config file for this in v6.0.0.

## What this protocol does NOT do

- Cross-host coordination. The lock file lives in `./.doer/`, gitignored per-clone. Two devs on two machines are never in conflict.
- Cooperative scheduling. There is no queue or wait. Conflict = fail fast.
- File-level locks on the source tree. Stage 4's git operations rely on the user not running `/wk:doer` twice on the same branch; the per-ticket lock is the enforcement, not file-level OS locks.
