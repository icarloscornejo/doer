---
name: locale
description: >-
  Sets the chat narration locale, globally across every project. Invoke as
  "/wk:locale <code>" (e.g. /wk:locale es) or bare "/wk:locale" to be asked.
  Any ISO 639-1 code. Chat narration only; committed artifacts (code, commit
  messages, PR descriptions) always stay English. Part of the wk plugin's
  configuration surface, alongside "/wk:setup" and "/wk:jira".
version: 7.1.0
user-invocable: true
allowed-tools: [Read, Bash, AskUserQuestion]
---

# /wk:locale - set chat narration locale

Global, personal, same in every repo. Does not touch Jira config or run the Workspace Guard (no `.doer/` write).

1. If `<code>` was given, run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" set-locale "<code>"` directly.
2. If no `<code>` was given, `AskUserQuestion`: offer the current locale (`preferences.sh get-locale`), `English`, and a custom option; then run `set-locale` with the answer.
3. Confirm IN the new locale.
