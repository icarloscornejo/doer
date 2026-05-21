---
name: review
description: >-
  Review an external pull request (GitHub or GitLab) with configurable advisor
  personas (security, performance, mobile, a11y, api). Optionally posts the
  findings as a PR review comment. Personas are shared with /wk:advise.
version: 6.0.0
user-invocable: true
allowed-tools: [Read, Write, Bash, Agent]
---

# Review. External PR Review

User-facing skill for reviewing a pull request or merge request that lives outside the local repository (i.e., a PR the dev did NOT generate via the `/wk:doer` pipeline). Fetches PR metadata, diff, and comments from the platform CLI, then dispatches one or more advisor personas from `lib/advisor-personas/` in parallel. Produces a structured report, and optionally posts it back to the platform as a review comment.

**How it differs from `/wk:advise`:** `wk:advise` is spec-first and local (it reviews specs, ACs, or files from the current working tree). `wk:review` is FETCH-FIRST: it gathers PR context from a remote platform before dispatching personas. It targets a coworker's PR, not a ticket in flight.

---

## Commands

| Command | Description |
|---------|-------------|
| `/wk:review <pr-ref>` | Review using the default persona set from `preferences.md` (`review_default_personas`; defaults to `["security"]` if unset). |
| `/wk:review <pr-ref> --personas <id1>,<id2>,...` | Override the persona set for this invocation. |
| `/wk:review <pr-ref> --persona <id>` | Single-persona shortcut (equivalent to `--personas <id>`). |
| `/wk:review <pr-ref> --post` | After generating the report, post it as a review comment via the platform CLI. |
| `/wk:review --list-personas` | List all available personas from `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/`. |

---

## PR-ref Forms

The `<pr-ref>` argument accepts the following forms.

**Full URL:**
- GitHub: `https://github.com/<owner>/<repo>/pull/<N>`
- GitLab: `https://gitlab.com/<group>/<repo>/-/merge_requests/<N>`

**Short form:**
- GitHub: `<owner>/<repo>#<N>` (e.g. `acme/backend#42`)
- GitLab: `<group>/<repo>!<N>` (e.g. `acme/backend!42`)

**Bare number inside a clone with a single remote:**
- GitHub: `#<N>` (e.g. `#42`). The skill resolves the remote from `git remote get-url origin`.
- GitLab: `!<N>` (e.g. `!42`). Same resolution.

**Auto-detection logic:**
- If the host is `github.com` or the short form uses `#`, use `gh`.
- If the host is `gitlab.com` or the short form uses `!`, use `glab`.
- If a bare number is given without a sigil, ask the user once: "Is this a GitHub PR (`#`) or a GitLab MR (`!`)?"

---

## Required CLIs and Auth

| Platform | CLI | Install | Auth |
|----------|-----|---------|------|
| GitHub | `gh` | `brew install gh` / [cli.github.com](https://cli.github.com) | `gh auth login` |
| GitLab | `glab` | `brew install glab` / [gitlab.com/gitlab-org/cli](https://gitlab.com/gitlab-org/cli) | `glab auth login` |

Before fetching anything, the skill checks that the required CLI is available:

```bash
command -v gh   # for GitHub refs
command -v glab # for GitLab refs
```

If the CLI is missing, the skill exits with a clear message:

```
ERROR: 'gh' is not installed or not on PATH. Install it with 'brew install gh' and run 'gh auth login' before retrying.
```

Do NOT attempt to fall back to raw `curl`/`git` operations. The platform CLIs handle auth, pagination, and field normalization.

---

## Workspace Guard

MANDATORY before any fetch or persona dispatch:

- The cwd MUST NOT be `~` or `/` (or their absolute expanded equivalents: `$HOME` or the filesystem root). If cwd is either of those paths, exit immediately:
  ```
  ERROR: /wk:review must be run from a project directory, not from ~ or /.
  ```
  This matches the workspace-guard pattern used by all skills in the `wk` plugin (see `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`).

---

## Persona Model

Personas are defined in `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/`. Each persona is a JSON file named `<id>.json`. The skill reads persona definitions at runtime; it does NOT redefine the schema here.

To list available personas:

```bash
ls "${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/"
```

Each persona JSON is expected to provide (at minimum) a `system_prompt`, a `focus_checklist`, `out_of_scope`, and an `output_schema`. See `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/` for the authoritative schema and available persona IDs.

**`--list-personas` behavior:**
1. List all `*.json` files in `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/`.
2. For each file, print `<id>` and the first line of its `system_prompt` (or a `description` field if present).
3. Exit. Do not proceed to any fetch.

---

## Procedure

Follow these numbered steps in order on every invocation (except `--list-personas`, which exits after step 1).

### Step 0: Workspace Guard

Run the workspace-guard check described above. Abort on failure.

### Step 1: Parse the pr-ref

Parse `<pr-ref>` to extract:
- `platform`: `github` or `gitlab`
- `owner`: org or group
- `repo`: repository name
- `number`: PR/MR number (integer)

For bare `#<N>` / `!<N>` refs, run:

```bash
git remote get-url origin
```

Parse `owner` and `repo` from the remote URL (handles both HTTPS and SSH forms).

Verify the required CLI is available (see "Required CLIs" above). Abort with the error message if missing.

### Step 2: Read preferences and resolve persona set

Read `${CLAUDE_PLUGIN_ROOT}/preferences.md`. Extract `review_default_personas` (array of IDs). If the key is absent, default to `["security"]`.

If `--personas` or `--persona` was given on the command line, use that list instead (override).

For each resolved persona ID, verify that `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/<id>.json` exists. For any missing ID, narrate a warning and remove it from the list. If the list becomes empty, exit with:

```
ERROR: No valid personas remain after resolution. Run '/wk:review --list-personas' to see available IDs.
```

### Step 3: Fetch PR context from the platform

**GitHub:**

```bash
# Metadata
gh pr view "<owner>/<repo>#<N>" \
  --json title,body,author,headRefName,baseRefName,additions,deletions,labels,state,reviewDecision

# Diff
gh pr diff "<owner>/<repo>#<N>"

# Top-level review comments
gh pr view "<owner>/<repo>#<N>" --comments
```

**GitLab:**

```bash
# Metadata
glab mr view <N> --repo "<owner>/<repo>" -F json

# Diff
glab mr diff <N> --repo "<owner>/<repo>"

# Notes (comments)
glab mr note list <N> --repo "<owner>/<repo>"
```

Capture all three outputs (metadata JSON, diff text, comments text) in memory. Do NOT write them to disk. Do NOT write them to any file in cwd or in `.doer/`. The fetched content is ephemeral context for this invocation only.

**Privacy and safety:** do NOT inline any local `.env` file, any shell environment variable containing secrets, or any credential found in cwd into the Agent prompts below. The PR diff is the only external content that goes to the Agents.

### Step 4: Dispatch personas in parallel

Issue one Agent call per persona in a SINGLE tool block (parallel dispatch). Each Agent receives its own persona context and the full PR content.

**Agent prompt template for each persona (fill in the placeholders):**

```
You are an advisor performing a code review of an external pull request.

== Persona ==
<contents of ${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/<id>.json, full JSON>

Use the persona's `system_prompt` as your framing.
Stay within the persona's `focus_checklist` and do not address items in `out_of_scope`.

== PR Metadata ==
<metadata JSON from Step 3>

== PR Diff ==
<diff text from Step 3>

== PR Comments ==
<comments text from Step 3>

== Task ==
Review the pull request above through the lens of your persona.
Output your findings as a JSON array matching the persona's `output_schema`.
Each finding MUST be an object with these fields:
  {
    "severity": "blocker | high | medium | low | info",
    "title":    "<short title, one line>",
    "where":    "<file path and line or range, e.g. src/auth.ts:42 or N/A>",
    "explain":  "<one to three sentences explaining the finding>",
    "fix":      "<concrete suggested fix or 'N/A' if no actionable fix>"
  }

Output ONLY a valid JSON array. No prose before or after the array.

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All output MUST be in English.
```

Wait for all Agents to return before proceeding.

### Step 5: Aggregate findings into the report

Collect the JSON arrays returned by each Agent. Parse each array. Attribute each finding to its source persona.

**Aggregate findings by severity within each persona section:**

Priority order (highest first): `blocker`, `high`, `medium`, `low`, `info`.

**Report template:**

```
## PR Review: <owner>/<repo>#<N> "<title>"

Personas: <comma-separated persona IDs>

### <PersonaDisplayName> findings (<count>)
- [BLOCKER] <title> at <where>
  <explain>
  Suggested fix: <fix>
- [HIGH] ...
- [MEDIUM] ...
...

(Repeat the section above for each persona.)

### Summary
<One line per persona: "<PersonaID>: <N> blocker(s), <N> high, <N> medium, <N> low, <N> info">
Overall vote: <approve | comment | request_changes>
```

**Vote rule (deterministic, apply in order):**

1. If ANY finding across ANY persona has `severity == "blocker"`, vote is `request_changes`.
2. Else if ANY finding has `severity == "high"`, vote is `comment`.
3. Else, vote is `approve`.

The vote reflects what this review would recommend as a formal GitHub/GitLab review action.

### Step 6: Output or post the report

**Without `--post`:**

Print the report to stdout. Exit.

**With `--post` on GitHub:**

Determine the `gh pr review` flag from the vote:
- `request_changes` vote: use `--request-changes`
- `comment` or `approve` vote: use `--comment`

(Note: never use `--approve` automatically. Approval requires human intent.)

```bash
gh pr review "<owner>/<repo>#<N>" \
  --request-changes \       # or --comment
  --body "<report text>"
```

**With `--post` on GitLab:**

GitLab does not support automated approve/reject via `glab` in this skill. Post a comment only:

```bash
glab mr note create <N> \
  --repo "<owner>/<repo>" \
  --message "<report text>"
```

The GitLab vote line in the report still reflects the recommended action (so the dev knows what to do manually), but the skill does not call `glab mr approve` or `glab mr merge`.

After posting, narrate: "Report posted to <platform> <owner>/<repo>#<N>."

---

## Output Format Reference

The full report structure:

```
## PR Review: acme/backend#42 "Add OAuth2 refresh token rotation"

Personas: security, performance

### Security findings (3)
- [BLOCKER] Refresh token not invalidated on reuse at src/auth/token.ts:88
  The old refresh token remains valid after rotation. An attacker who
  intercepts a token can keep using it indefinitely.
  Suggested fix: Invalidate the previous token in the same transaction
  that issues the new one.
- [HIGH] Token stored in localStorage at src/auth/storage.ts:14
  localStorage is accessible to any JS on the page, making it vulnerable
  to XSS exfiltration.
  Suggested fix: Store tokens in httpOnly cookies or in-memory only.
- [LOW] Missing rate limit on /auth/refresh at src/routes/auth.ts:201
  No rate limiting means brute-force is possible on the refresh endpoint.
  Suggested fix: Add a sliding-window rate limiter (e.g. 10 req/min/IP).

### Performance findings (1)
- [MEDIUM] N+1 query on user roles at src/auth/rbac.ts:55
  For each request, roles are fetched in a loop without batching.
  Suggested fix: Load all relevant roles in a single query before the loop.

### Summary
security: 1 blocker, 1 high, 0 medium, 1 low, 0 info
performance: 0 blockers, 0 high, 1 medium, 0 low, 0 info
Overall vote: request_changes
```

---

## Worked Examples

### Example 1: GitHub PR with blocker findings

```
/wk:review acme/backend#42 --personas security,performance
```

1. Platform: GitHub. CLI: `gh`.
2. Personas: `security`, `performance`. Both JSON files found in `lib/advisor-personas/`.
3. Fetch: `gh pr view acme/backend#42 --json ...`, `gh pr diff acme/backend#42`, `gh pr view acme/backend#42 --comments`.
4. Dispatch two Agents in parallel (one per persona).
5. Security agent returns 3 findings (1 blocker, 1 high, 1 low). Performance agent returns 1 finding (1 medium).
6. Vote: blocker present, so `request_changes`.
7. Report printed to stdout. (No `--post`, so no network call.)

### Example 2: GitHub PR with no blockers (clean approval path)

```
/wk:review acme/frontend#101
```

1. Platform: GitHub. No `--personas` flag. Read `preferences.md`: `review_default_personas: ["security"]`.
2. Fetch PR context via `gh`.
3. Dispatch one Agent (security persona).
4. Security agent returns 2 findings: 1 medium, 1 low.
5. Vote: no blocker, no high, so `approve`.
6. Report printed to stdout. Vote line reads: "Overall vote: approve".

### Example 3: GitLab MR, comment-only post

```
/wk:review https://gitlab.com/acme/api/-/merge_requests/7 --persona api --post
```

1. Platform: GitLab (host is `gitlab.com`). CLI: `glab`.
2. Persona: `api`. JSON file found.
3. Fetch: `glab mr view 7 --repo acme/api -F json`, `glab mr diff 7 --repo acme/api`, `glab mr note list 7 --repo acme/api`.
4. Dispatch one Agent (api persona).
5. API persona returns 2 findings: 1 high (missing versioning header), 1 info.
6. Vote: high present but no blocker, so `comment`.
7. `--post` is set. GitLab path: post a note only (no auto-approve/auto-reject).
   ```bash
   glab mr note create 7 --repo acme/api --message "<report text>"
   ```
8. Narrate: "Report posted to GitLab acme/api!7."

---

## Error Reference

| Condition | Message |
|-----------|---------|
| cwd is `~` or `/` | `ERROR: /wk:review must be run from a project directory, not from ~ or /.` |
| Required CLI not found | `ERROR: 'gh' is not installed or not on PATH. Install it with 'brew install gh' and run 'gh auth login' before retrying.` |
| Persona ID not found | Warning: `Persona '<id>' not found in lib/advisor-personas/. Skipping.` |
| All personas invalid | `ERROR: No valid personas remain after resolution. Run '/wk:review --list-personas' to see available IDs.` |
| Ambiguous bare number | Ask once: "Is this a GitHub PR (`#`) or a GitLab MR (`!`)?" |
| Agent returns non-JSON | Log the raw output, skip the persona's findings with a warning, continue with remaining personas. |

---

## Design Notes

- Persona definitions are owned by `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/`. This skill is a consumer; it does NOT define or modify persona schemas.
- The parallel Agent dispatch follows the same pattern documented in `skills/doer/SKILL.md` under "Parallel subagents (opt-in)" (WK-6). Each Agent is independent; the orchestrator waits for all before aggregating.
- The fetched PR diff is treated as untrusted external content. It is passed to Agents as read-only context. No code in the diff is executed.
- Em-dashes are prohibited in all skill output, Agent prompts, and the posted report. Self-check before every output: scan for U+2014 and U+2013 and rewrite if found.
