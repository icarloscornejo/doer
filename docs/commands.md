# Commands in detail

Every stage of every command. Back to the [README](../README.md).

## Setup

```bash
/wk:setup
```

Guided, three steps: locale (global, personal; optional), Jira base URL for
this project (optional; needed for `/wk:bugfix` and doer's auto-fetch), and the
name of the env var holding your Jira token (defaults to `JIRA_PAT`; only
needed if your token already lives under another name). Or set each piece
individually:

```bash
/wk:locale es        # any ISO 639-1 code. Chat narration only; artifacts stay English. Global.
/wk:jira https://jira.your-company.com   # this project only
export JIRA_PAT="<your Jira PAT>"        # full-token, session-only, never written to disk
```

Locale is global and personal
(`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json`, survives plugin
upgrades). Jira config is **per-project** (`./.doer/config.json`,
git-excluded), because different repos can point at different Jira instances.
The token itself is never stored anywhere; only the name of the env var that
holds it.

To update the plugin: `/plugins` panel, `wk`, Update now; or
`claude plugin update wk@wk` and restart Claude Code.

## `/wk:doer` in 5 stages

```
1 AC + Intake  ->  2 Plan (native plan mode)  ->  3 Build (tests + code + review loop x3)
                                              ->  4 Verify (on device, via protologs)
                                              ->  5 Wrapup (lessons + commit msg + PR desc)
```

- **Stage 1** captures the ticket (paste or Jira auto-fetch), confirms testable
  ACs as Given/When/Then scenarios (BDD-style; a trivial cosmetic change gets a
  plain bullet instead), and detects pre-existing work (plan, tests or code you
  already had skip you ahead).
- **Stage 2** designs the plan in Claude Code's plan mode; your approval is the
  gate. Assumptions get mechanical pre-flight checks.
- **Stage 3** is the doer and reviewer loop (max 3 iterations): the test-writer
  derives failing tests from the Given/When/Then scenarios (tests-first) or adds
  regression tests alongside a trivial change (code-first), the code-writer
  makes them pass, and a reviewer returns findings in 4 buckets (BLOCKER,
  AUTO_FIX, SUGGESTION, INFO); the stage exits only with the full suite green.
- **Stage 4** never auto-skips: it always asks, then instruments the vertical
  slice with `protologs`, you exercise the ACs on device, an analyzer maps logs
  to verdicts, and cleanup is verified.
- **Stage 5** validates assumptions, captures lessons into the global pool,
  checks docs, and delivers a copy-paste commit message and PR description
  (with optional auto-squash).

### Day-to-day

| Command | Description |
|---|---|
| `/wk:doer <TICKET-ID>` | Start new or resume (auto-detected). |
| `/wk:doer <TICKET-ID> --no-pr` | Start a ticket on a branch that merges straight to the base branch: Stage 5 still squashes to one commit, skips the PR description, and closes with "merge and push when you approve". Per ticket, stored in the ticket, ignored on resume. `/wk:bugfix <KEY> --no-pr` does the same. |
| `/wk:doer status <TICKET-ID>` | Current stage, loop state, blockers. |
| `/wk:doer list` | All tickets (doer and bugfix) under `./.doer/tickets/`. |
| `/wk:doer cleanup-history <TICKET-ID>` | Scrub `.doer/` from branch history (auto-offered at wrapup). |

Stopping: close the session (state persists after every step) or write `stop`,
`wait` or `hold on`. Anything else at a turn boundary means "continue". Resume
anytime with `/wk:doer <TICKET-ID>`.

## `/wk:bugfix` in 7 stages

```
0 Init -> 1 Ingest Jira -> 2 Gather attachments -> 3 Digest evidence + entry points
       -> 4 Investigate (plan mode) -> verdict -> 5 Fix OR mini-spike -> 6 Verify on device
```

- Designed to run in **opusplan**: the mechanical stages run cheap, the
  investigation runs on the strongest model.
- **Stage 2** is opportunistic: whatever evidence the ticket happens to have
  gets pulled in; a ticket with nothing attached just moves on to Stage 3.
  Network captures (Charles `.chls`, converted to `.har` via `makehar` or
  Charles.app when available) and screenshots are the common case, not a
  requirement.
- **Stage 3** digests the evidence by grepping for the ticket's technical
  signals, never read whole, before plan mode starts, so Stage 4 never needs
  `Bash`. It also recovers known investigation entry points for the ticket's
  topic from the per-repo `./.doer/entry-points.json` store (a "for X always
  start at file Y" mapping the dev builds up over tickets) and offers them by
  default, instead of asking cold every time.
- **The verdict is data-driven:** `app_bug` leads to plan, fix and `protologs`
  verification; `not_app_bug` (API, CMS, backend, data, env) leads to an
  evidence-first mini-spike in Jira markup, posted as a comment only with your
  explicit yes.

Control state lives in `./.doer/tickets/<KEY>/` (never reaches git); heavy
artifacts (network captures, screenshots, the spike) in `~/Downloads/<KEY>/`
for easy manual inspection.

## `/wk:replay`

Emulates a bug scenario at full fidelity directly in the app's own source, so
it reproduces on a device regardless of the actual backend content, feature
flags, or A/B bucket.

- **Not a proxy, not an interceptor, not a mock server:** the forced data flows
  through the app's own parser and mappers, so the injection point is the
  deserialization seam (the app's own call site plus its own configured Gson,
  Moshi or kotlinx instance), never the transport layer.
- **Two techniques, combinable:** a captured Charles or HAR response forced at
  that seam, or an internal flag or kill switch forced at its read site.
- **Runs only after the real fix is already committed**, so its
  `[TEMP] REPLAY` commit's diff contains only the forced scaffolding.
- Exactly two log lines per forced site (`PROTOLOG_RESPONSE - `, entry and
  applied), never protologs' full density.
- `/wk:bugfix` Stage 6 offers it before `/wk:protologs`, but it works
  standalone in any repo with no dependency on `bugfix.json`.
- `cleanup` reverts its own commits (never protologs'), verified by a
  restore-equality check so a text-based fallback can catch the deletions the
  injection makes, not just additions.

## `/wk:protologs`

Instruments a targeted diagnostic slice of your current diff: entry point, then
boundary, then observable result, capped at 3 hops upward and cut at the first
external boundary downward.

- **Flat density:** function entry and exit, branches taken, catches, plus
  collections, nullables, suspend points and emits only when the value sits on
  the verified data path, using only the language's basic stdout with the tag
  `PROTOLOG - `.
- Hops cut by the hop budget are reported, not silently dropped, and you can
  ask for an extra round on any of them.
- Backs up the pre-inject state to /tmp, compiles what it touched, and prints
  the filter command (`adb logcat | grep "PROTOLOG - "`).
- `cleanup` deletes every tagged line, restores files it touched outside your
  diff, and verifies zero trace remains. Never commits or pushes.
