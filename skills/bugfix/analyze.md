# Stage 4 - Investigation, Analysis & Verdict

Read this only when you reach Stage 4. You are in **plan mode (Opus)**. Goal: reach a defensible **root cause** and a **verdict**, then produce a `plan{}`. Do not edit code here - planning only. Plan mode is read-only tools only (`Read`/`Grep`/`Glob`); no `Bash`. Everything that needed `Bash` (downloading, converting, parsing the HARs) already ran in Stage 3, before `EnterPlanMode`, since plan mode does not inherit the session's own permission mode and a `Bash` call in here would prompt for approval on every invocation.

Inputs already on disk: `bugfix.json` (`signals`, `attachments`, `entry_points`, `evidence` - the HAR/screenshot digest Stage 3 already built), `ticket.md` (raw description + comments). Do not re-parse `charles/*.har` or `screenshots/*.png` here; if the existing `evidence[]` is missing something only a re-parse would give, note the gap and its effect on confidence instead of running `Bash`.

---

## 1. Correlate with the code

Locate the code that governs the observed behavior, using `Read`/`Grep`/`Glob` on the repo:
- If `entry_points` are real paths → start there. If it is `"search"` → find the owning code from `signals.technical` (grep for the flag/function/endpoint names).
- Trace from the network behavior in `evidence[]` back to the branch/gate/mapper that decides it. Identify the exact line(s) responsible.

---

## 2. Decide the verdict

Weigh the evidence honestly. The verdict is data-driven, not a default.

**`app_bug`** - the defect is in this codebase. Signals:
- A gate / mapper / branch / state handling in the app produces the wrong outcome for inputs that are themselves valid.
- The HAR shows the app sending a wrong/absent/malformed request, or mishandling a well-formed response.
- A code path at/above the entry points explains the repro and a plausible change fixes it.

**`not_app_bug`** - the app behaves correctly given its inputs; the fault is upstream/external. Signals:
- The API returns wrong/missing data, or a different status/shape than contracted.
- CMS/Contentful content is mis-flagged/mis-published (the app faithfully honors bad config).
- Backend/data/environment issue; the same build behaves differently only because upstream state changed.
- Already fixed by another change/ticket and no longer reproduces on the current branch.

If confidence is low, say so and state what additional evidence (a specific request, a build, a flag dump) would settle it - do not force a verdict.

---

## 3. Produce the plan

### verdict = `app_bug`
```json
"plan": {
  "type": "fix",
  "root_cause": "<one paragraph, cites the responsible file:line and the evidence>",
  "steps": [{"order": 1, "what": "<change>", "where": "<File.kt:120-140>"}],
  "tests": ["<what to add/adjust and which behavior it locks>"]
}
```

### verdict = `not_app_bug`
```json
"plan": {
  "type": "spike",
  "root_cause": "<one paragraph: what actually fails and why it is not the app>",
  "spike_owner": "API | CMS | Backend | Data | Env"
}
```

---

## 4. Confirm

Present to the user, concisely:
- **Verdict** + confidence.
- **Root cause** with the key evidence (session delta, file:line).
- **Plan**: the fix steps + tests, or the spike owner + headline finding.

Get explicit confirmation. On approval → `ExitPlanMode`, then ONE `metadata.sh write ... --file bugfix.json` that sets `verdict`, `plan`, and `stages.4 = "complete"` together. If the user pushes back, revise within plan mode before exiting.
