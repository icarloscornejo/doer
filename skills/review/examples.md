# Review Worked Examples

Reference-only. Read on demand to see how a full external-PR review run looks end-to-end.

---

## Example 1: GitHub PR with blocker findings

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

---

## Example 2: GitHub PR with no blockers (clean approval path)

```
/wk:review acme/frontend#101
```

1. Platform: GitHub. No `--personas` flag. Resolve via `preferences.sh get-flag review_default_personas` (returns `security`).
2. Fetch PR context via `gh`.
3. Dispatch one Agent (security persona).
4. Security agent returns 2 findings: 1 medium, 1 low.
5. Vote: no blocker, no high, so `approve`.
6. Report printed to stdout. Vote line reads: "Overall vote: approve".

---

## Example 3: GitLab MR, comment-only post

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
