# Publish Worked Examples

Reference-only. Read on demand to see how a full publish run looks end-to-end.

---

## Example 1. GitHub draft PR

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

---

## Example 2. GitLab MR with custom base

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

---

## Example 3. GitHub PR with Jira transition

Developer finishes ticket `PLAT-99` linked to Jira via `/wk:load` (`metadata.intake.tracker.kind == "jira"`). Wants to transition the ticket to "In Review" after PR creation.

```
/wk:publish PLAT-99 --transition "In Review"
```

Execution:
1. Checks 1-4 pass.
2. Platform is GitHub. `gh auth status` succeeds.
3. PR created at `https://github.com/org/platform/pull/212`. `metadata.publish` persisted.
4. `--transition "In Review"` is set and `metadata.intake.tracker.kind == "jira"`. Proceeding with Jira transition (read `${CLAUDE_PLUGIN_ROOT}/lib/jira-transition.md`).
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
