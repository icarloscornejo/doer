# --reuse: Updating an Existing PR/MR

Reference-only. Loaded by `/wk:publish` when `--reuse` is passed and `metadata.publish` already exists.

---

## Flow

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

## Push divergence

If `--reuse` IS set and the branch already exists on the remote, a plain `git push` (non-force) is still used. If the push is rejected (diverged history), abort and ask the dev to resolve the divergence manually:

```
ABORT: push rejected; local branch and remote branch have diverged.
Resolve manually (rebase, reset, or force-push if appropriate), then re-run /wk:publish --reuse.
```

---

## --reuse without prior publish

If `--reuse` is passed but `metadata.publish` does NOT exist, treat the run as a first-time publish (create, not update). Do not error.
