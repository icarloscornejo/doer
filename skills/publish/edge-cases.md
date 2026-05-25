# Publish Edge Cases

Reference-only. Read on demand when a publish run aborts or behaves unexpectedly.

---

## Detached HEAD

If `git rev-parse --abbrev-ref HEAD` returns `HEAD` (detached), abort at Check 3:

```
ABORT: repository is in detached HEAD state. Check out the feature branch first:
  git checkout <branch from metadata.branch>
Then re-run /wk:publish.
```

---

## No remote configured

If `git remote get-url origin` fails, abort at the platform detection step:

```
ABORT: no remote named 'origin' found.
Add the remote: git remote add origin <URL>
Then re-run /wk:publish.
```

---

## Required CLI not installed

If `gh` or `glab` is not on PATH, abort after platform detection:

```
ABORT: platform detected as GitHub but 'gh' is not installed.
Install it from https://cli.github.com/ and run 'gh auth login', then re-run.

ABORT: platform detected as GitLab but 'glab' is not installed.
Install it from https://gitlab.com/gitlab-org/cli and run 'glab auth login', then re-run.
```

---

## Authentication failure

If `gh auth status` or `glab auth status` exits non-zero, abort:

```
ABORT: gh authentication check failed. Run 'gh auth login' and re-run /wk:publish.
ABORT: glab authentication check failed. Run 'glab auth login' and re-run /wk:publish.
```

Authentication failure for the Jira API (HTTP 401 or 403 on the transitions call) does NOT roll back the PR/MR. The error is recorded in `metadata.publish.jira_transition.error` and the dev is instructed to re-run with `--reuse --transition`.

---

## metadata.json missing

```
ABORT: .doer/tickets/<TICKET-ID>/metadata.json not found.
Has the ticket been started with /wk:doer? Expected path: .doer/tickets/<TICKET-ID>/metadata.json
```

---

## Ticket not complete

```
ABORT: ticket <TICKET-ID> status is "<current status>", not "complete".
Finish all 9 doer stages (/wk:doer <TICKET-ID>) before publishing.
```
