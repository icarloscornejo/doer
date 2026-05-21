---
name: publish
description: >-
  Create a Pull Request (GitHub) or Merge Request (GitLab) for a completed
  doer ticket, optionally transitioning the linked Jira ticket. Opt-in step
  at the end of the pipeline; doer itself stops before PR creation.
version: 6.0.0
user-invocable: true
allowed-tools: [Read, Write, Bash]
---

# Publish. PR/MR Creation + Tracker Transition

Satellite skill of the `wk` plugin. Takes a completed doer ticket (status `complete` in `metadata.json`), pushes the feature branch, and creates a Pull Request on GitHub or a Merge Request on GitLab. Jira transition is opt-in. The doer pipeline deliberately stops before pushing or creating a PR; `/wk:publish` is the explicit final hop the dev runs when ready.

**Scope:** push branch, create PR/MR, optionally transition Jira. No code changes, no commits, no CI.

**Out of scope:** linting, running tests, squashing commits, merging, deployment.

---

## When to Run

Run `/wk:publish` after `/wk:doer` reports `status: complete` on the ticket. Do not run it while the doer pipeline is still in progress. The skill checks for `status == "complete"` in `metadata.json` and aborts if that condition is not met.

---

## Invocation Forms

```
/wk:publish <TICKET-ID>
```
Push the branch and create a PR/MR with the default base branch (`main`).

```
/wk:publish <TICKET-ID> --draft
```
Create a draft PR/MR. Useful when you want reviewers to see the work but the ticket is not ready for merge.

```
/wk:publish <TICKET-ID> --base <branch>
```
Override the merge target. Default is `main`. Use this when the ticket targets a release branch or a long-lived feature branch.

```
/wk:publish <TICKET-ID> --transition <state>
```
After creating the PR/MR, also transition the linked Jira ticket to the named state (e.g. `--transition "In Review"`). Requires `metadata.intake.tracker.kind == "jira"`. Errors otherwise.

```
/wk:publish <TICKET-ID> --dry-run
```
Print what would be done (branch push, PR/MR title, body preview, Jira transition if applicable) without executing any write operation.

```
/wk:publish <TICKET-ID> --reuse
```
If the branch is already published and a PR/MR already exists (`metadata.publish` present), update the existing PR/MR body and title to match the latest metadata instead of creating a new one.

**Combined flags are allowed.** Examples:

```
/wk:publish ABC-123 --draft --base release/2.0
/wk:publish ABC-123 --reuse --transition "In Review"
/wk:publish ABC-123 --dry-run --transition "In Review"
```

---

## Pre-flight Checks

Run all checks in order. Abort on the first failure with a clear error message naming which check failed and why.

### Check 1. Workspace guard

The current working directory MUST contain a `.git/` directory and MUST NOT be `~` or `/`. Refer to `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md` for the canonical guard protocol.

```bash
[ -d .git ] || { echo "ABORT: not a git repository (no .git/ in cwd)"; exit 1; }
[ "$(pwd)" != "$HOME" ] || { echo "ABORT: cwd is home directory. Navigate to the target repo."; exit 1; }
[ "$(pwd)" != "/" ] || { echo "ABORT: cwd is filesystem root."; exit 1; }
```

### Check 2. Metadata invariants

Read `.doer/tickets/<TICKET-ID>/metadata.json`. All four conditions MUST hold:

- `status == "complete"`. The doer pipeline must have finished all 9 stages.
- `branch` is a non-empty string.
- `summary` is a non-empty string (used as the PR/MR body summary).
- `last_green_sha` is exactly 40 hex characters matching `git rev-parse <branch>`.

If any condition fails, narrate which one and abort. Examples:

```
ABORT: metadata.json not found at .doer/tickets/ABC-123/metadata.json.
ABORT: ticket ABC-123 status is "in_progress", not "complete". Finish the doer pipeline first.
ABORT: metadata.branch is empty. Cannot determine which branch to push.
ABORT: metadata.last_green_sha is 7 characters; must be the full 40-char SHA.
ABORT: metadata.last_green_sha (abc123...40chars) does not match git rev-parse feature/abc-123 (def456...40chars). The branch tip drifted after Stage 9.
```

### Check 3. HEAD matches last_green_sha

```bash
CURRENT_HEAD=$(git rev-parse HEAD)
```

`CURRENT_HEAD` MUST equal `metadata.last_green_sha`. If the working tree has uncommitted changes or the branch tip drifted (e.g. a manual commit after Stage 9), abort:

```
ABORT: current HEAD (abc...) differs from metadata.last_green_sha (def...).
You have uncommitted changes or new commits since Stage 9 completed.
Options: commit or stash the changes, then re-run /wk:publish.
```

### Check 4. Remote reachable

```bash
git ls-remote origin HEAD > /dev/null 2>&1 || {
  echo "ABORT: cannot reach remote 'origin'. Check network or run: git remote -v"
  exit 1
}
```

If the remote is not reachable, abort with the error message. Do not attempt a push.

---

## Platform Detection

Read the `origin` remote URL:

```bash
ORIGIN_URL=$(git remote get-url origin)
```

Match against known patterns to determine `PLATFORM`:

| Pattern | Platform | CLI |
|---------|----------|-----|
| `github.com` in URL | GitHub (cloud) | `gh` |
| `ghe.` or `/ghe.` in URL, or any enterprise domain in `GH_HOST` env var | GitHub Enterprise | `gh` |
| `gitlab.com` in URL | GitLab (cloud) | `glab` |
| `gitlab.` in hostname, or self-hosted GitLab pattern | GitLab self-hosted | `glab` |

If the URL matches neither pattern, abort:

```
ABORT: remote origin URL (<URL>) does not match a supported platform.
Supported: github.com (and GitHub Enterprise), gitlab.com (and self-hosted GitLab).
Set GH_HOST or GITLAB_HOST env vars for enterprise hosts, then re-run.
```

After determining `PLATFORM`, verify the required CLI is installed and authenticated:

```bash
# GitHub
gh auth status 2>&1 || { echo "ABORT: gh is not installed or not authenticated. Run: gh auth login"; exit 1; }

# GitLab
glab auth status 2>&1 || { echo "ABORT: glab is not installed or not authenticated. Run: glab auth login"; exit 1; }
```

---

## PR/MR Creation Procedure

### Step 1. Abort if already published (without --reuse)

If `metadata.publish` already exists and `--reuse` is NOT set, abort:

```
ABORT: a PR/MR was already created for ticket <TICKET-ID> (<URL>).
Use --reuse to update the existing PR/MR instead of creating a new one.
```

### Step 2. Push the branch

```bash
git push -u origin <branch>
```

If the branch already exists on the remote and `--reuse` is NOT set, abort:

```
ABORT: branch <branch> already exists on remote but --reuse was not passed.
Use --reuse to update the existing PR/MR, or delete the remote branch and re-run.
```

If `--reuse` IS set and the branch already exists, a plain `git push` (non-force) is still used. If the push is rejected (diverged history), abort and ask the dev to resolve the divergence manually:

```
ABORT: push rejected; local branch and remote branch have diverged.
Resolve manually (rebase, reset, or force-push if appropriate), then re-run /wk:publish --reuse.
```

### Step 3. Compose the PR/MR body

Write the body to a temporary file (e.g. `/tmp/wk-publish-<TICKET-ID>.md`). Template:

```
## Summary
<metadata.summary>

## ACs
<bulleted list from metadata.ac.in_scope; one bullet per item>

## Plan
<bulleted list of metadata.plan.steps[].what in step order>

## Tests
<bulleted list of metadata.plan.tests[].name>

## Lessons captured
<bulleted list formatted as "slug -- takeaway" for each entry in metadata.lessons_captured[]>
If metadata.lessons_captured is empty or absent, write: "(none)".

## Tracker
<metadata.intake.tracker.source_url if metadata.intake.tracker exists and source_url is non-empty, else "n/a">

---
Generated by /wk:publish (wk plugin 6.0.0).
```

Use `Write` to produce the temp file. Never leave the temp file on disk after the skill exits (clean up in a `trap`-style final step regardless of success or failure).

### Step 4. Derive the title

```
[<TICKET-ID>] <metadata.title>
```

### Step 5. Issue the create command

**GitHub (cloud or enterprise):**

```bash
gh pr create \
  --base <base> \
  --head <branch> \
  --title "[<TICKET-ID>] <title>" \
  --body-file /tmp/wk-publish-<TICKET-ID>.md \
  [--draft]
```

**GitLab (cloud or self-hosted):**

```bash
glab mr create \
  --target-branch <base> \
  --source-branch <branch> \
  --title "[<TICKET-ID>] <title>" \
  --description-file /tmp/wk-publish-<TICKET-ID>.md \
  [--draft]
```

Capture the full URL from stdout.

### Step 6. Persist metadata.publish

After a successful create, read `metadata.json`, add the `publish` block, and write back:

```json
"publish": {
  "platform": "github | gitlab",
  "url": "<full URL returned by gh/glab>",
  "branch": "<branch>",
  "base": "<base branch>",
  "draft": <true | false>,
  "created_at": "<ISO8601>",
  "reused": false
}
```

### Step 7. Narrate outcome

```
PR created: <URL>
Branch: <branch> -> <base>
Draft: <yes | no>
Jira transition: <pending | skipped>
```

---

## --reuse: Updating an Existing PR/MR

When `--reuse` is passed and `metadata.publish` already exists:

1. Skip the "abort if already published" guard.
2. Push the branch (same push step; non-force).
3. Recompose the body using the same template (metadata may have changed since the last publish run).
4. Update the existing PR/MR:

   **GitHub:**
   ```bash
   gh pr edit "<URL or branch>" \
     --title "[<TICKET-ID>] <title>" \
     --body-file /tmp/wk-publish-<TICKET-ID>.md
   ```

   **GitLab:**
   ```bash
   glab mr update "<MR IID>" \
     --title "[<TICKET-ID>] <title>" \
     --description-file /tmp/wk-publish-<TICKET-ID>.md
   ```

5. Update `metadata.publish`:
   - Keep `url`, `platform`, `branch`, `base`, `draft`, `created_at` unchanged.
   - Set `reused: true`.
   - Set (or overwrite) `last_updated_at: "<ISO8601>"`.

6. Narrate:
   ```
   PR/MR updated: <URL>
   Body and title refreshed from latest metadata.
   ```

---

## Jira Transition (Opt-in)

Only runs when ALL of the following are true:
- `--transition <state>` was passed.
- `metadata.intake.tracker.kind == "jira"` (provenance from `/wk:load` or manually set in metadata).

If `--transition` is passed but `metadata.intake.tracker.kind` is NOT `"jira"`, abort the transition with a clear message. Do NOT roll back the PR/MR already created:

```
PR/MR created successfully: <URL>
WARN: Jira transition requested but intake.tracker.kind is not "jira" (got: "<actual kind>").
Skipping transition. The PR/MR is live.
```

### Resolve the transition ID

Required environment variables:
- `WK_JIRA_EMAIL`: Jira account email.
- `WK_JIRA_TOKEN`: Jira API token (not password).
- `WK_JIRA_BASE_URL`: Jira base URL (e.g. `https://myorg.atlassian.net`).

If any variable is unset, abort the transition step only (PR/MR is already created):

```
PR/MR created successfully: <URL>
ABORT (Jira transition only): WK_JIRA_EMAIL, WK_JIRA_TOKEN, and WK_JIRA_BASE_URL must be set.
Set them and re-run /wk:publish <TICKET-ID> --transition "<state>" --reuse to retry.
```

Fetch available transitions:

```bash
JIRA_ID=$(echo "<metadata.ticket_id>" | sed 's/^WK-//')  # use the raw ticket id for Jira
curl -s \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<jira-id>/transitions" \
  | jq '.transitions[] | {id: .id, name: .name}'
```

Find the transition whose `name` matches the requested state (case-insensitive):

```bash
TRANSITION_ID=$(curl -s \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<jira-id>/transitions" \
  | jq -r --arg state "<requested state lowercased>" \
    '.transitions[] | select((.name | ascii_downcase) == $state) | .id')
```

If no matching transition is found, fail the transition step only:

```
PR/MR created successfully: <URL>
WARN: no Jira transition named "<state>" found on ticket <jira-id>.
Available transitions: <comma-separated list of .name values>.
Skipping. Re-run /wk:publish --reuse --transition "<correct name>" to retry.
```

### POST the transition

```bash
HTTP_STATUS=$(curl -s -o /tmp/jira-transition-response.json -w "%{http_code}" \
  -X POST \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"transition\": {\"id\": \"${TRANSITION_ID}\"}}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<jira-id>/transitions")
```

A `204` response indicates success. Any other status code is a failure.

### On success

Persist into `metadata.publish.jira_transition`:

```json
"jira_transition": {
  "to_state": "<requested state as passed>",
  "transition_id": "<id>",
  "transitioned_at": "<ISO8601>"
}
```

Narrate:

```
Jira ticket <jira-id> transitioned to "<state>".
```

### On failure

Persist into `metadata.publish.jira_transition`:

```json
"jira_transition": {
  "error": "HTTP <status>: <first 200 chars of response body>"
}
```

Narrate:

```
PR/MR created successfully: <URL>
ERROR (Jira transition): HTTP <status>. See metadata.publish.jira_transition.error.
Re-run /wk:publish <TICKET-ID> --reuse --transition "<state>" after resolving auth.
```

Exit with a non-zero code so the dev knows the Jira step failed and the PR/MR was not rolled back.

---

## metadata.publish Schema

Full shape after a successful run:

```json
"publish": {
  "platform": "github | gitlab",
  "url": "<full PR/MR URL>",
  "branch": "<feature branch name>",
  "base": "<target branch, e.g. main>",
  "draft": false,
  "created_at": "<ISO8601>",
  "reused": false,
  "last_updated_at": "<ISO8601 | null; set only on --reuse runs>",
  "jira_transition": {
    "to_state": "<requested state>",
    "transition_id": "<id>",
    "transitioned_at": "<ISO8601>"
  }
}
```

`jira_transition` is absent if `--transition` was not passed. It is set to `{"error": "..."}` if the transition was attempted but failed.

---

## Idempotency

The skill is safe to re-run with `--reuse`. Without `--reuse`, it aborts if `metadata.publish` already exists. This prevents accidentally creating duplicate PRs/MRs.

| Scenario | Behavior |
|----------|----------|
| First run, branch not on remote | Push + create PR/MR + persist metadata.publish |
| First run, branch already on remote, no --reuse | ABORT: branch already published |
| --reuse, metadata.publish exists | Push (non-force) + update PR/MR + update last_updated_at |
| --reuse, metadata.publish does NOT exist | Treat as first run (create, not update) |
| Repeated --reuse runs | Safe; body and title are recomposed from latest metadata each time |
| Jira transition failure | PR/MR persisted; transition error recorded; non-zero exit |
| --dry-run | No push, no PR/MR, no Jira call; only print what would happen |

---

## --dry-run Mode

When `--dry-run` is passed, skip all write operations and print a preview:

```
DRY RUN: no changes will be made.

Would push branch: <branch> -> origin
Would create PR/MR on: <platform> (<origin URL>)
Title: [<TICKET-ID>] <title>
Base: <base>
Draft: <yes | no>

--- PR/MR body preview ---
<full composed body>
--------------------------

Jira transition: <"Would transition <jira-id> to '<state>'" | "Not requested">
```

Dry-run does NOT write `metadata.publish`. It is safe to run repeatedly.

---

## Edge Cases

### Detached HEAD

If `git rev-parse --abbrev-ref HEAD` returns `HEAD` (detached), abort at Check 3:

```
ABORT: repository is in detached HEAD state. Check out the feature branch first:
  git checkout <branch from metadata.branch>
Then re-run /wk:publish.
```

### No remote configured

If `git remote get-url origin` fails, abort at the platform detection step:

```
ABORT: no remote named 'origin' found.
Add the remote: git remote add origin <URL>
Then re-run /wk:publish.
```

### Required CLI not installed

If `gh` or `glab` is not on PATH, abort after platform detection:

```
ABORT: platform detected as GitHub but 'gh' is not installed.
Install it from https://cli.github.com/ and run 'gh auth login', then re-run.

ABORT: platform detected as GitLab but 'glab' is not installed.
Install it from https://gitlab.com/gitlab-org/cli and run 'glab auth login', then re-run.
```

### Authentication failure

If `gh auth status` or `glab auth status` exits non-zero, abort:

```
ABORT: gh authentication check failed. Run 'gh auth login' and re-run /wk:publish.
ABORT: glab authentication check failed. Run 'glab auth login' and re-run /wk:publish.
```

Authentication failure for the Jira API (HTTP 401 or 403 on the transitions call) does NOT roll back the PR/MR. The error is recorded in `metadata.publish.jira_transition.error` and the dev is instructed to re-run with `--reuse --transition`.

### metadata.json missing

```
ABORT: .doer/tickets/<TICKET-ID>/metadata.json not found.
Has the ticket been started with /wk:doer? Expected path: .doer/tickets/<TICKET-ID>/metadata.json
```

### Ticket not complete

```
ABORT: ticket <TICKET-ID> status is "<current status>", not "complete".
Finish all 9 doer stages (/wk:doer <TICKET-ID>) before publishing.
```

---

## Worked Examples

### Example 1. GitHub draft PR

Developer finishes ticket `FEAT-42` on branch `feature/add-dark-mode`. No Jira link.

```
/wk:publish FEAT-42 --draft
```

Execution:
1. Check 1: `.git/` present, cwd is not `~` or `/`. Pass.
2. Check 2: `metadata.json` exists, `status == "complete"`, `branch == "feature/add-dark-mode"`, `summary` is non-empty, `last_green_sha` is 40 chars and matches `git rev-parse feature/add-dark-mode`. Pass.
3. Check 3: current HEAD matches `last_green_sha`. Pass.
4. Check 4: `git ls-remote origin HEAD` succeeds. Pass.
5. Platform detection: `origin` URL contains `github.com`. Platform is GitHub.
6. `gh auth status` succeeds.
7. No `metadata.publish` exists. Proceeding.
8. `git push -u origin feature/add-dark-mode` succeeds.
9. Body composed and written to `/tmp/wk-publish-FEAT-42.md`.
10. `gh pr create --base main --head feature/add-dark-mode --title "[FEAT-42] Add dark mode" --body-file /tmp/wk-publish-FEAT-42.md --draft` returns `https://github.com/org/repo/pull/88`.
11. `metadata.publish` persisted with `platform: "github"`, `url`, `draft: true`.
12. Temp file removed.

Narration:
```
PR created: https://github.com/org/repo/pull/88
Branch: feature/add-dark-mode -> main
Draft: yes
Jira transition: skipped (not requested)
```

### Example 2. GitLab MR with custom base

Developer finishes ticket `BE-7` targeting the `develop` branch on a self-hosted GitLab instance.

```
/wk:publish BE-7 --base develop
```

Execution:
1. Checks 1-4 pass.
2. Platform detection: `origin` URL is `git@gitlab.mycompany.com:backend/api.git`. Pattern matches GitLab self-hosted. Platform is GitLab.
3. `glab auth status` succeeds.
4. No `metadata.publish` exists. Proceeding.
5. `git push -u origin feature/be-7-fix-auth` succeeds.
6. Body composed. `glab mr create --target-branch develop --source-branch feature/be-7-fix-auth --title "[BE-7] Fix auth token expiry" --description-file /tmp/wk-publish-BE-7.md` returns `https://gitlab.mycompany.com/backend/api/-/merge_requests/14`.
7. `metadata.publish` persisted with `platform: "gitlab"`, `base: "develop"`, `draft: false`.

Narration:
```
MR created: https://gitlab.mycompany.com/backend/api/-/merge_requests/14
Branch: feature/be-7-fix-auth -> develop
Draft: no
Jira transition: skipped (not requested)
```

### Example 3. GitHub PR with Jira transition

Developer finishes ticket `PLAT-99` linked to Jira via `/wk:load` (`metadata.intake.tracker.kind == "jira"`). Wants to transition the ticket to "In Review" after PR creation.

```
/wk:publish PLAT-99 --transition "In Review"
```

Execution:
1. Checks 1-4 pass.
2. Platform is GitHub. `gh auth status` succeeds.
3. PR created at `https://github.com/org/platform/pull/212`. `metadata.publish` persisted.
4. `--transition "In Review"` is set and `metadata.intake.tracker.kind == "jira"`. Proceeding with Jira transition.
5. `WK_JIRA_EMAIL`, `WK_JIRA_TOKEN`, `WK_JIRA_BASE_URL` are all set. Proceeding.
6. Fetch transitions for `PLAT-99`. Match `"In Review"` (case-insensitive) to transition ID `31`.
7. POST transition. HTTP 204. Success.
8. `metadata.publish.jira_transition` persisted.
9. Temp file removed.

Narration:
```
PR created: https://github.com/org/platform/pull/212
Branch: feature/plat-99-logging -> main
Draft: no
Jira transition: PLAT-99 transitioned to "In Review".
```
