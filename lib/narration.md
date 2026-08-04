# Narration Protocol

How wk skills communicate with the user: narration discipline, turn boundaries, interaction mechanism, locale, and the em-dash rule.

## Narration first

The orchestrator narrates what it is doing and why, at every meaningful step: before dispatching an Agent, when a check fails, when a decision is made. The user must always know where the pipeline is so they can pause at any point. Long operations emit progress lines, not just a final summary. Terse is fine; silent is not.

## Em-dashes prohibited

Zero `—` (U+2014) and `–` (U+2013) characters anywhere: chat, metadata values, lessons, commit messages, PR descriptions, code comments. Use commas, periods, semicolons, parentheses, or sentence breaks. Append to every sub-agent prompt: *"Em-dashes are forbidden. Use commas, periods, or parentheses instead."* Self-check before sending any output.

## Turn boundaries: auto-proceed by default

The only events that end a turn:

1. An `AskUserQuestion` call (the tool itself ends the turn).
2. An Agent returned an error the user must see before retrying.
3. The user typed a halt signal (`stop`, `wait`, `hold on`).
4. A plain-chat question asking for approval, edits, or rejection of an already-drafted team-facing artifact (PR description, spike). The artifact goes to chat as plain text and the turn ends right there; persisting it or closing the ticket before the dev's reply is prohibited.

Everything else, including stage transitions and loop iterations, chains in the same turn. MUST NOT ask "Continue?" / "Shall I proceed?" / "Ready for Stage N?" between stages or iterations; the user opted in by starting the ticket. Narrate *"Stage N complete. Continuing to Stage N+1..."* and keep going.

After a turn DID end, interpret the next user message as: a halt signal → stop and narrate how to resume; a direct answer to the question just asked → use it; anything else (`ok`, `yes`, an unrelated comment, empty) → read `metadata.json` and run the next pending action without further prompting.

## AskUserQuestion vs plain chat

| The answer is... | Mechanism |
|---|---|
| A closed set of 2-4 mutually exclusive options, or binary | `AskUserQuestion` |
| Open free text (a command, a branch name, pasted content, edit instructions) | Plain-chat question |
| Long or multiline (an artifact the dev pastes) | Plain-chat question |
| Approval of a long artifact the orchestrator drafted (PR description, spike) | Plain-chat question, AND a turn boundary (see event 4 above); never `AskUserQuestion`, a draft never goes inside the tool |
| "Continue? / Proceed?" between stages | NEITHER; auto-proceed |

`AskUserQuestion` rules: the tool auto-appends a free-text "Other" (never hand-author one); 4 real options max; mark the recommended choice `(Recommended)`.

## Locale

Resolve via `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" get-locale` as the first action of every invocation (falls back to `en`). Switch anytime with `/wk:locale <code>`.

**Two scopes, different rules:**

| Scope | Language |
|---|---|
| Live chat (narration, questions, summaries) | Operating locale |
| Persistent state (every `metadata.json` string, lessons, commit messages, PR text) | **Always English** |

Artifacts are consumed by other sub-agents and future tickets across projects; one language keeps them shareable. Append to every sub-agent prompt: *"All artifacts you write (markdown, JSON, code comments, commit messages) MUST be in English, regardless of the chat language."* Do not drift to English in chat because surrounding context is English; the operating locale wins. There is no `metadata.locale`; the global preferences file is the only source.
