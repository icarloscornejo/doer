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

| Flag | Effect |
|------|--------|
| (none) | Push branch, create PR/MR against `main`. |
| `--draft` | Create a draft PR/MR. |
| `--base <branch>` | Override merge target (default `main`). |
| `--transition <state>` | After PR/MR creation, transition the linked Jira ticket. Requires `metadata.intake.tracker.kind == "jira"`. |
| `--dry-run` | Print the plan (branch push, title, body, Jira call) without executing any write. |
| `--reuse` | Update the existing PR/MR (when `metadata.publish` already present) instead of creating a new one. See `${CLAUDE_PLUGIN_ROOT}/skills/publish/reuse.md`. |

Flags combine freely. Examples: `--draft --base release/2.0`, `--reuse --transition "In Review"`, `--dry-run --transition "In Review"`.

---

## Pre-flight Checks

Run all checks in order. Abort on the first failure with a clear error message naming which check failed and why.

### Check 1. Workspace guard

Run the canonical guard from `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`. The minimum invariants `/wk:publish` enforces:

- cwd contains a `.git/` directory.
- cwd is NOT `$HOME` and NOT `/`.

Abort on the first failed invariant with the standard messages from the guard protocol.

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

For the `--reuse` push behavior (non-force, divergence handling), see `reuse.md`.

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

GitHub:
```bash
gh pr create --base <base> --head <branch> \
  --title "[<TICKET-ID>] <title>" \
  --body-file /tmp/wk-publish-<TICKET-ID>.md [--draft]
```

GitLab:
```bash
glab mr create --target-branch <base> --source-branch <branch> \
  --title "[<TICKET-ID>] <title>" \
  --description-file /tmp/wk-publish-<TICKET-ID>.md [--draft]
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

## --reuse Flow

When `--reuse` is passed, follow the protocol in `${CLAUDE_PLUGIN_ROOT}/skills/publish/reuse.md`. It owns: skipping the already-published guard, the non-force push step, the GitHub/GitLab update commands, and the `metadata.publish` update fields (`reused: true`, `last_updated_at`).

If `--reuse` is passed but `metadata.publish` does NOT exist, treat the run as a first-time publish.

---

## Jira Transition (Opt-in)

Only runs when ALL of the following are true:
- `--transition <state>` was passed.
- `metadata.intake.tracker.kind == "jira"` (provenance from `/wk:load` or manually set in metadata).

When both conditions hold, read `${CLAUDE_PLUGIN_ROOT}/lib/jira-transition.md` and follow that protocol. It owns: env-var requirements, transition ID resolution, the POST call, success/failure persistence into `metadata.publish.jira_transition`, and the narration templates.

If `--transition` is passed but `metadata.intake.tracker.kind` is NOT `"jira"`, skip the transition step (PR/MR stays live) and narrate:

```
PR/MR created successfully: <URL>
WARN: Jira transition requested but intake.tracker.kind is not "jira" (got: "<actual kind>").
Skipping transition. The PR/MR is live.
```

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

Skip all write operations (push, create, edit, Jira POST) and print a preview block: branch and target, title, base, draft flag, full composed body, and the Jira step status (`Would transition <jira-id> to '<state>'` or `Not requested`).

Dry-run does NOT write `metadata.publish`. Safe to run repeatedly.

---

## Edge Cases

Abort conditions for detached HEAD, missing remote, missing CLI, auth failure, missing `metadata.json`, and incomplete ticket are documented in `${CLAUDE_PLUGIN_ROOT}/skills/publish/edge-cases.md`. Read on demand when a run aborts.

---

## Worked Examples

Three end-to-end runs (GitHub draft PR, GitLab MR with custom base, GitHub PR with Jira transition) live in `${CLAUDE_PLUGIN_ROOT}/skills/publish/examples.md`. Read on demand only when verifying expected behavior.
