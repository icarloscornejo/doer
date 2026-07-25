Mini-spike template (Jira wiki markup).

Use this when verdict = not_app_bug. Fill from bugfix.json (signals, evidence, analysis, plan.spike_owner)
and ticket.md. Output goes to ~/Downloads/<KEY>/spike.md. Keep it tight and evidence-first.

Voice:
- Senior and direct. State the finding, do not soften it. No "it seems", "it appears", "possibly".
- One bullet, one idea. If a bullet needs "and also", split it into two bullets.
- Bold lead-in on every interpretive bullet (e.g. "*Same component, same data, different label:*"),
  explanation follows on the same line.
- Explain the why only when it changes what the reader does with the information.
- The document ends when the last idea ends. No "Overall...", no "let me know if you need anything else".
- Do not sound corporate/academic/AI-generated: avoid "therefore", "however", "additionally", "furthermore".
- No U+2014 or U+2013 anywhere. Already covered by lib/narration.md, repeated here because this template
  is read in isolation.

Guidance:
- h2 title = the finding in one line (what actually happens + who owns it).
- TL;DR = bold-lead-in bullets, not loose prose. Canonical slots: what happens, why it happens, why it
  is not the app, who owns it. Collapse slots only when two genuinely overlap.
- Evidence heading = name the source with real provenance: the Charles session filename(s), build, QA
  environment, and what was compared (e.g. logged-out loads of the same page across locales).
- Evidence table: pick the shape that actually carries the delta.
  - Session-delta shape, when repro and working are two separate captures:
    || Session || Build || <key flag> || <measured signal> ||
  - Within-session shape, when what changes is a dimension inside one capture (locale, flag, user):
    || Signal || Value || What it shows ||
  - Selection rule: the columns are the dimensions that expose the delta. If two rows differ in exactly
    one column, that column is the finding.
- "Reading the table" bullets: add a bold-lead-in bullet block right after the table only when there is
  more than one signal to interpret, or the read is not obvious from the table alone. Skip it when the
  root cause is one line and the table already speaks for itself. When included, close with a
  "*Net effect:*" bullet that reduces the block to the one actionable conclusion.
- Root cause panel(s): red (the broken path) and green (the correct/fixed path) when there is one.
  Use {code:java} / {code} for snippets. Cite the exact gate/flag/response field.
- "Reading the trace" bullets: same rule as "Reading the table", applied to the root cause panel. Only
  when there is real interpretation to do; close with "*Net effect:*" when included.
- Fix/Recommendation section, in bullets: what would actually resolve this; the "not an app change"
  disclaimer when it applies; the green panel with the corrected config/response; the concrete ask to
  the owning team; and a blast-radius bullet (spot-check other entries/configs) when the same defect
  could exist elsewhere.
- Close with "cc [~accountid]" for the owner and reporter when known. Omit the line if neither is known.
- No U+2014 and no double-dashes (--) in the body (Jira markup + house style).

======================================================================
TEMPLATE (copy below this line, replace <...>)
======================================================================

h2. Spike: <one-line finding, e.g. "<KEY> is not an app bug: <owner> returns/flags X">

*TL;DR:*
* *What happens:* <the reported symptom, in one sentence>
* *Why:* <the upstream cause, cite the exact field/flag/config>
* *Why it's not the app:* <the app honors its inputs as-is; no code path branches on this>
* *Owner:* <team/system that owns the fix, or the fixing PR/ticket if already resolved>

h3. Evidence (<source, e.g. "Charles session: <file>.chls", build, env, what was compared>)

|| Signal || Value || What it shows ||
| <signal 1> | <value> | <what it demonstrates> |
| <signal 2> | *<value>* | <what it demonstrates> |

<optional: Reading the table, only when there is more than one signal to interpret>
* *<lead-in>:* <interpretation>
* *<lead-in>:* <interpretation>
* *Net effect:* <one line, the actionable conclusion>

h3. Root cause

{panel:title=🔴 <the broken path / wrong input>|borderColor=#DE350B|titleBGColor=#FFEBE6|bgColor=#FFF5F3}
{code:java}
<snippet or response fragment showing the fault>
{code}
{panel}

<optional: Reading the trace, only when there is real interpretation to do>
* *<lead-in>:* <why this produces the reported symptom, citing the exact field/flag/gate>
* *Net effect:* <one line, the actionable conclusion>

h3. Fix

* *The fix that would resolve this situation is:* <the concrete corrected value/config/behavior>
* *Not an Android/app change:* <why the app is already correct given its inputs, when applicable>

{panel:title=🟢 Requested action|borderColor=#006644|titleBGColor=#E3FCEF|bgColor=#F0FFF4}
{code:java}
<snippet of the fix, or the corrected config/response>
{code}
{panel}

* *Ask <owning team> to:* <the concrete action needed>
* <optional: blast-radius bullet, spot-check other entries/configs for the same defect>

cc [~<owner accountid>] [~<reporter accountid>]
