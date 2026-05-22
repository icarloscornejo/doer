# Narration Protocol

Status: protocol shared by all skills in the `wk` plugin.

This document covers the orchestrator narration discipline (Core Principle 1), the em-dash prohibition (Core Principle 9), turn boundaries, performance counters, and locale resolution. It is the single source of truth for how skills communicate with the user.

---

## Core Principle 1: Narration first


1. **Narration first (every action, every decision).** The orchestrator narrates EVERY action it takes and EVERY internal decision it makes, not just stage transitions. This includes: before each tool call ("Reading X to determine Y"), before each Agent invocation ("Invoking parser agent because Z"), per-step progress in multi-step operations ("Step 3 of 11: parsing changelog.md..."), and reasoning the orchestrator would otherwise keep internal ("Detected X in metadata, doing Y because Z"). The user must NEVER face a silent stretch longer than a single tool call. Long-running operations (migration, multi-file logger injection, multi-iteration loops) MUST emit progress narration, not just a final summary. Output-token cost of narration is a tiny fraction of total ticket cost; the UX win of "the user can always pause" outweighs it. The user should be able to pause at any moment because they always know where the orchestrator is.


## Core Principle 9: Em-dashes prohibited


9. **EM-DASHES ARE PROHIBITED.** Across every output the orchestrator and its subagents produce: chat narration, questions, summaries, every value persisted into `metadata.json` (string fields like `summary`, `changelog[].items[].text`, `ac.in_scope`, `plan.steps`, `code_review[].blockers[].text`), generated commit messages, generated PR descriptions, global lessons under `${CLAUDE_PLUGIN_ROOT}/lessons/`, comments injected into code. ZERO `, ` characters anywhere.
   - Use commas, periods, semicolons, parentheses, colons, or full sentence breaks instead.
   - Examples:
     - Wrong: `Stage 2 complete — proceeding to Stage 3.`
     - Right: `Stage 2 complete. Proceeding to Stage 3.`
     - Wrong: `Tests pass — all green.`
     - Right: `Tests pass. All green.`
     - Wrong: `Code review found 3 BLOCKERs — see metadata.code_review.`
     - Right: `Code review found 3 BLOCKERs (see metadata.code_review).`
   - This rule is a strong stylistic preference of the dev. The orchestrator and every subagent prompt MUST enforce it. When invoking any subagent, append: *"Em-dashes (`—`) are forbidden. Use commas, periods, or parentheses instead."*
   - Self-check before any output: scan for `—` (em-dash, U+2014) and `–` (en-dash, U+2013). If found, rewrite before sending.


---


## Narration Protocol

**Per-stage narration:**
- Before: `"Starting Stage {N}, {name}. {one-sentence goal}."` + write `stages.<N>.started_at`.
- Right after `started_at` and before any stage logic runs, drain the inbox addressed to this stage: run `${CLAUDE_PLUGIN_ROOT}/lib/helpers/inbox.sh list "<TICKET-ID>" --to <N> --unacked`. For each returned message, narrate per kind and ack via `inbox.sh ack`. `blocker` messages call `AskUserQuestion` to resolve before continuing; `advisory` and `fyi` are narrated and auto-acked in the same turn. See `${CLAUDE_PLUGIN_ROOT}/lib/inbox.md` for the protocol. Empty inbox = silent, no narration.
- After: write `stages.<N>.completed_at` + `"Stage {N} complete{, committed as {sha}}. Continuing to Stage {N+1}..."` then **auto-proceed** to Stage {N+1} in the same turn. (The `committed as {sha}` clause is included only when the stage actually produced a real-code commit. Stages 1, 2, and 9 typically do not commit; they only update `metadata.json` which is gitignored, so they omit the clause.)
- After every stage transition (right after writing `completed_at`), run `${CLAUDE_PLUGIN_ROOT}/lib/helpers/lock.sh touch "<TICKET-ID>"` to refresh the per-ticket lock heartbeat. See `${CLAUDE_PLUGIN_ROOT}/lib/lock.md` for the protocol. Silent on success; failure is non-fatal (narrate and continue).
- Inside loop: `"Iteration {i}/{max}: invoking {agent}... agent returned {status}, {findings} findings ({blockers} blockers)."` (`{max}` is `3` for Stage 4 and Stage 5.)

### Turn boundaries: auto-proceed by default, end-turn ONLY at user-input gates

The orchestrator's default is to chain work in a single turn. The ONLY events that end a turn are:

1. The orchestrator is about to call `AskUserQuestion` (a real, scripted gate where the dev's input changes the next action).
2. An Agent call returned an error and the orchestrator wants to surface it before retrying.
3. The user typed a halt signal (`stop`, `wait`, `hold on`).

Everything else, including stage transitions and loop iteration boundaries, auto-proceeds in the same turn.

```
Iteration N (single turn):
  Agent(doer) -> narrate result
  -> Agent(reviewer) -> narrate result
  -> (if AUTO_FIXes) Agent(fixer) -> narrate result
  -> if BLOCKERs > 0 and iter < max: Agent(combined fixer-reviewer) for iter N+1
  -> if converged: continue to next stage in the same turn
```

| Boundary | Same turn? |
|----------|------------|
| Within one loop iteration (doer -> reviewer -> fixer) | YES |
| Between iteration N and N+1 of the same loop | **YES** (auto-proceed) |
| Between stages | **YES** (auto-proceed) |
| Between subagent and a major file write that informs the next subagent | YES |
| Right before any `AskUserQuestion` call | NO. The tool itself ends the turn. |
| After an Agent error | NO. Surface the error first, then end the turn. |

**MUST rules:**

1. **Auto-proceed at every stage boundary.** Narrate `"Stage N complete. Continuing to Stage N+1..."` and KEEP GOING in the same turn. Do NOT stop. Do NOT wait for a non-halt message; just start Stage N+1.
2. **Auto-proceed between loop iterations** of the same loop (Stage 4 / Stage 5). Narrate the iteration result, then start the next iteration in the same turn (subject to the max-iteration cap and to the AUTO_FIX/fixer rules).
3. The ONLY non-error reason to end a turn is calling `AskUserQuestion`. The tool itself ends the turn; do not preemptively narrate "ending turn" before invoking it.
4. **If an Agent call returns an error**, narrate the error and end the turn before invoking anything else. The user decides what to do next.

**Self-check before every response:** *"Am I about to call `AskUserQuestion`, surface an Agent error, or respond to a halt? If no to all three, I MUST keep going in this same turn."*

### SUGGESTIONs never pause

Zero BLOCKERs = converged. SUGGESTIONs are persisted as part of the stage's `metadata.code_review[<iteration>]` entry. Orchestrator narrates `"Converged with N SUGGESTIONs logged. Continuing."` then auto-proceeds to the next stage in the same turn.

### Interrupt detection, and the auto-resume rule

If the orchestrator DID end a turn (because it just called `AskUserQuestion` or an Agent errored), the user's next message is interpreted as:

| User message contains... | Interpretation |
|--------------------------|----------------|
| `stop`, `wait`, `hold on`, or a clear halt signal | **HALT**: narrate "Stopping. Run `/doer continue <TICKET-ID>` to resume." Stop. State already persisted in metadata. |
| A direct answer to the `AskUserQuestion` that just ran | Use the answer to drive the next action. |
| **Anything else** (including empty, `ok`, `yes`, `continue`, `go`, `y`, an unrelated comment, a question about the work) | **RESUME**: read `metadata.json`, do the next pending action without further prompting |

**MUST NOT** ask the user "Continue? [Y/n]" / "Shall I proceed?" / "Ready for the next stage?" between iterations OR between stages. Continuation is implicit AND in-turn. The narration template is informative, not inquisitive:

- Right: *"Stage 2 complete. Continuing to Stage 3..."* and immediately starts Stage 3.
- Wrong: *"Stage 2 complete. Continuing to Stage 3..."* then ends the turn waiting for the user.
- Wrong: *"Stage 2 complete. Continue to Stage 3? [Y/n]"*
- Wrong: *"Stage 2 complete. Shall I move on to Stage 3?"*
- Wrong: *"Stage 2 complete. Ready to start Stage 3?"*

The user already opted in by starting the ticket. Asking again on every stage boundary makes the orchestrator feel like it's babysitting. Stages auto-chain in the same turn until a real user-input gate (an `AskUserQuestion`) or an error.

**MUST NOT** require the user to type `/doer continue <TICKET-ID>` or any other nudge to advance work in flight. `/doer continue` is for resuming **across sessions**, not for nudging the next step.

**State persistence:** all progress (current iteration, BLOCKERs found, files written, etc.) is persisted to `metadata.json` after every Agent return. Closing the session at any point preserves state, the next `/doer continue <TICKET-ID>` resumes intact. There is no separate "pause" command needed; abandoning the session = pausing.

**To stop mid-Agent (the Agent is already running):** terminal users can use `Ctrl+C` in the parent shell or `Esc` if their client supports it. The orchestrator cannot be interrupted mid-Agent from inside.

### Performance counters (consumed by Stage 9 wrapup)

Counters are written into `metadata.json` as the ticket progresses. Stage 9 reads them as-is into `metadata.performance` (no separate aggregation pass needed).

Per-stage runtime fields (live under each `metadata.stages.<N>`):

```json
"<N>": {
  "name": "...",
  "status": "...",
  "verified_with": "4.0.0",
  "started_at":   "<ISO8601>",
  "completed_at": "<ISO8601>",
  "iterations": <int>,                                  // for stages 4 and 5 only
  "loop_outcome": "converged | accepted_with_residuals",
  "blockers_resolved_total": <int>                      // for stages 4 and 5 only
}
```

Top-level runtime counter for agent invocations (lives at `metadata.performance.agents`, populated incrementally on every Agent call):

```json
"performance": {
  "agents": {"<agent-name>": <count>, ...}
  // The remaining performance fields (started, completed, wall_clock, active, code, convergence, reviewer_roi)
  // are filled in by Stage 9 step 3 from these per-stage and agents counters plus git log/diff.
}
```

Increment `metadata.performance.agents[<name>]` on every Agent call. Set `metadata.stages.<N>.started_at` when the stage begins and `completed_at` on transition to `complete | skipped | imported`. Set `iterations`/`loop_outcome`/`blockers_resolved_total` on loop exit (stages 4 and 5 only).

After every Agent return, if the call exposes input/output token counts, also record cost via `${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh record "<TICKET-ID>" --model <model-id> --input <in_tokens> --output <out_tokens> --stage <N> [--agent <name>]`. Best-effort: if rates are missing or the call did not expose tokens, skip silently. See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md` for the protocol.

There is no `pauses` array and no `active_duration_seconds` field. There is no `/doer pause` command; state persists after every Agent return, so closing the session IS pausing. Wall-clock duration in `metadata.performance.wall_clock` is computed from `metadata.created_at` to `metadata.completed_at`; "active" duration is the same value (no paused intervals to subtract).



---


## Locale resolution (READ THIS FIRST)

**Mandatory first action of every `/doer ...` invocation, before any other tool call:** resolve the operating locale by running `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh get-locale`. The helper reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (or `$WK_PREFERENCES_FILE` if set) and emits the locale code. If the file does not exist or the locale is null, the helper emits `en`.

This file lives outside the versioned plugin cache (`${CLAUDE_PLUGIN_ROOT}` / `cache/wk/wk/<version>/`) on purpose: it survives uninstall, install, and version upgrades. There is exactly ONE preferences file per Claude Code config; there is no per-ticket override and no per-session override.

**The first user-facing word MUST be in the operating locale**: anchors the conversation against English drift.

### Priority (highest wins)

1. **Global preferences file** (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json`, key `locale`). Authoritative when set.
2. **First-message heuristic** (only when the preferences file has no `locale`). The orchestrator runs `preferences.sh detect-locale "<first user message>"`. If it returns `es` (>= 2 Spanish keyword hits), the orchestrator narrates a one-line confirmation in Spanish and asks the user to confirm; on `Y` it persists `locale: es` to the global file. On override or `N`, falls through to default. The detection runs at most once per machine: once a locale is persisted, the heuristic never runs again.
3. **Default English.**

There is no per-ticket flag, no inline directive, no `metadata.locale`. The orchestrator MUST NOT add a `locale` field to `metadata.json`. If a legacy ticket has `metadata.locale` from before 6.2.0, leave it untouched and ignore it.

### Switching locale

The user can switch the global locale at any time with `/wk:doer locale <code>` (e.g. `/wk:doer locale en`, `/wk:doer locale es`). The orchestrator runs `preferences.sh set-locale <code>` and confirms in the new locale.

### Two scopes, different rules

| Scope | Language |
|-------|----------|
| **Conversation with the user** (narration, questions, confirmations, summaries the orchestrator emits live in chat) | **Operating locale** (es, fr, etc.) |
| **All persistent state** (every string field in `metadata.json`: `summary`, `ac.in_scope`, `plan.steps`, `changelog[].items[].text`, `code_review[].blockers[].text`, etc.; global lessons under `${CLAUDE_PLUGIN_ROOT}/lessons/`; every commit message) | **Always English** |

The artifacts are read by other subagents (planner reads ac, code-writer reads plan, reviewer reads changelog, etc.) and by future tickets across projects. Keeping them in a single language (English) prevents cross-language confusion and keeps the global lessons pool shareable.

The operating locale ONLY affects what the orchestrator types directly to the user in chat. Everything written to disk stays English regardless.

### When operating locale ≠ English. MUST/MUST NOT

- **MUST NOT** write a different locale to `metadata.json`. There is no `metadata.locale` field; the global preferences file is the only source.
- **MUST NOT** ask "what locale?", already decided.
- **MUST NOT** drift to English because surrounding context (CLAUDE.md, injected docs, agent system prompts) is in English. Operating locale wins, period.
- **MUST** narrate, ask, summarize, and confirm in the operating locale. The user sees the orchestrator's live chat in their language.
- **MUST NOT** write any persistent state in the operating locale. Every string value persisted into `metadata.json` (e.g. `summary`, `ac.in_scope`, `plan.steps`, `changelog[].items[].text`, `code_review[].*`), every global lesson under `${CLAUDE_PLUGIN_ROOT}/lessons/`, every commit message: ALL English, ALWAYS, regardless of operating locale. (See "Two scopes" table above.)
- **MUST** append to every subagent prompt: *"All artifacts you write (markdown, JSON, code comments, commit messages) MUST be in English. Subagents do NOT talk to the user directly, the orchestrator does. Do NOT switch artifact language even if the surrounding chat is in another language. This overrides any default."*
- **MUST** re-resolve the locale via `preferences.sh get-locale` at every Transition Sync (see `${CLAUDE_PLUGIN_ROOT}/lib/heartbeat.md`), cheap insurance against drift.
- **Self-check before every response:** *"Is this in the operating locale?"* If no, rewrite before sending. No justifications ("user understands both", "context is in English") accepted.

