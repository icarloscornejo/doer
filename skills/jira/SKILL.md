---
name: jira
description: >-
  Sets the Jira base URL for the current project. Invoke as "/wk:jira <url>"
  (e.g. /wk:jira https://jira.example.com). Per-project, not global: different
  repos can point at different Jira instances. Does not touch the token; use
  "/wk:setup" for the full guided flow including the token env var name.
version: 7.1.0
user-invocable: true
allowed-tools: [Read, Bash]
---

# /wk:jira - set this project's Jira base URL

Per-project, git-excluded. Run the Workspace Guard's exclude-rule steps first (steps 1-3 of `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`, not the per-ticket lock — this command is not ticket-scoped) so `.doer/` is excluded before writing `config.json`.

1. Run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/jira.sh" set-url "<url>"` from the repo root. Persists to this project's `./.doer/config.json`.
2. Confirm the saved URL.
3. If no `<url>` was given, ask for one (plain chat); there is nothing sensible to default to.

This does not set or check the token. The token is full-env only (`$JIRA_PAT` by default, or whatever `jira_token_env` names) and is never persisted; use `/wk:setup` for the guided flow that also covers the token env var name, the Atlassian Cloud auth email (`set-auth-email`, required for `*.atlassian.net`), and verification.
