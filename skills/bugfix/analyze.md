# Stage 4 - Investigation, Analysis & Verdict

Read this only when you reach Stage 4. You are in **plan mode (Opus)**. Goal: reach a defensible **root cause** and a **verdict**, then produce a `plan{}`. Do not edit code here - planning only.

Inputs already on disk: `bugfix.json` (`signals`, `attachments`, `entry_points`), `ticket.md` (raw description + comments), `charles/*.har`, `screenshots/*.png`.

---

## 1. Build the evidence digest from the HARs

For each converted `.har`, extract ONLY the requests that matter - filter by `signals.technical` (endpoint ids, BO/context ids, flag names). Never read a whole HAR into context; they are huge.

```bash
python3 - "<charles/name.har>" "<term1>" "<term2>" <<'PY'
import json,sys
har=json.load(open(sys.argv[1])); terms=[t.lower() for t in sys.argv[2:]]
for e in har["log"]["entries"]:
    req=e["request"]; url=req["url"]
    blob=(url+" "+(e.get("response",{}).get("content",{}).get("text","") or "")).lower()
    if any(t in blob for t in terms):
        print(req["method"], e["response"]["status"], url[:160])
PY
```

Refine iteratively: grep response bodies for the specific identifiers (e.g. a context id present in one session and absent in another; a flag value; a status code). Distill each finding into a **one-line** entry in `evidence[]`:

```json
{"session": "repro",  "finding": "context=6x3Srun... never appears as a p13n request (0 calls)"}
{"session": "fixed",  "finding": "context=6x3Srun... fires x6 (logout+login, en-US/en-CA/fr-CA)"}
```

Prefer a comparative shape when the ticket has a repro vs fixed/working session - the delta between sessions is usually the whole story.

Read screenshots only if they add signal the HARs and text don't (UI state, error copy, toggle states).

---

## 2. Correlate with the code

Locate the code that governs the observed behavior:
- If `entry_points` are real paths → start there. If it is `"search"` → find the owning code from `signals.technical` (grep for the flag/function/endpoint names).
- Trace from the network behavior back to the branch/gate/mapper that decides it. Identify the exact line(s) responsible.

---

## 3. Decide the verdict

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

## 4. Produce the plan

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

## 5. Confirm

Present to the user, concisely:
- **Verdict** + confidence.
- **Root cause** with the key evidence (session delta, file:line).
- **Plan**: the fix steps + tests, or the spike owner + headline finding.

Get explicit confirmation. On approval → `ExitPlanMode`, persist `verdict` + `plan` into `bugfix.json`, mark stage 4 complete. If the user pushes back, revise within plan mode before exiting.
