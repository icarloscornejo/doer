---
name: setup
description: >-
  Guided, one-time-per-scope configuration for the wk plugin. Invoke as
  "/wk:setup". Walks through locale (global, personal) and this project's
  Jira base URL + token env var name (per-project, optional), then verifies
  Jira access and offers an auto-detect fallback for the token env var name
  if none is loaded. Use "/wk:locale <code>" or "/wk:jira <url>" instead for
  a one-shot change to a single piece.
version: 7.1.0
user-invocable: true
allowed-tools: [Read, Bash, AskUserQuestion]
---

# /wk:setup - guided configuration

Three steps, each skippable. If run inside a git repo, run the Workspace Guard's exclude-rule steps first (steps 1-3 of `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`, not the per-ticket lock — this command is not ticket-scoped) so `.doer/` is excluded before writing `config.json`.

## Step 1. Locale (global)

`AskUserQuestion`: offer the current locale (`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" get-locale`), `English`, and a custom option. On an answer, run `preferences.sh set-locale <code>`. This applies to every project.

## Step 2. Jira base URL (this project)

Plain-chat ask: *"Jira base URL for this project? (e.g. https://jira.example.com, or 'skip')"*. On a URL, run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/jira.sh" set-url <url>`. On skip, leave unset: Jira stays optional for `/wk:doer` and required-but-deferred for `/wk:bugfix`.

## Step 3. Jira token env var name (this project)

Only if step 2 was not skipped. Explain: the token is never written to disk, only the *name* of the env var that holds it. Default is `JIRA_PAT`. Plain-chat ask: *"Does your token already live in a different env var (e.g. JIRA_PROD_PAT)? Name it, or say 'use JIRA_PAT'."* On a custom name, run `jira.sh set-token-env <name>`.

## Step 3.5. Atlassian Cloud auth (only if the URL matches `*.atlassian.net`)

Cloud rejects Bearer tokens (403 "Failed to parse Connect Session Auth Token"); it requires HTTP Basic with `email:api_token`. Plain-chat ask: *"This looks like Atlassian Cloud. What email is your API token for? (from id.atlassian.com/manage-profile/security/api-tokens)"*. On an answer, run `jira.sh set-auth-email <email>`.

## Step 4. Verify + auto-detect fallback

Run `jira.sh config`. Report `{base_url, token_env}`. If `token_present: false`, run the auto-detect pass:

```bash
env | grep -iE 'JIRA.*(PAT|TOKEN)|TOKEN.*JIRA' | cut -d= -f1
```

Never print or persist the values, only the candidate NAMEs. Also check the project memory for a previously-noted token env var name (never a secret value). If exactly one clear candidate turns up and it differs from the configured `token_env`, ask via `AskUserQuestion` whether to point `jira_token_env` at it. Otherwise, tell the user to `export <TOKEN_ENV>="<their PAT>"` in this shell (or their `.zshrc` / `.envrc`) and that re-running `/wk:setup` or any Jira-backed command will pick it up.

Close with one line: what got configured, what's still pending (if anything), and that `/wk:bugfix` and `/wk:doer`'s auto-fetch are now ready.
