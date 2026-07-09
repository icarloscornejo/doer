Mini-spike template (Jira wiki markup).

Use this when verdict = not_app_bug. Fill from bugfix.json (signals, evidence, analysis, plan.spike_owner)
and ticket.md. Output goes to ~/Downloads/<KEY>/spike.md. Keep it tight and evidence-first.

Guidance:
- h2 title = the finding in one line (what actually happens + who owns it).
- TL;DR = 2-3 bullets a reader can act on without scrolling.
- Evidence table = one row per Charles session; columns are the dimensions that differ (build, flags, the
  measured signal). This is the spine of the spike; the session delta proves the point.
- Root cause panel(s) = red (🔴) for the broken path, green (🟢) for the correct/fixed path when there is one.
  Use {code:java} / {code} for snippets. Cite the exact gate/flag/response field.
- Close with ownership or the fixing reference (PR / ticket) if one exists.
- No em-dashes (—) and no double-dashes (--) in the body (Jira markup + house style).

======================================================================
TEMPLATE (copy below this line, replace <...>)
======================================================================

h2. Spike: <one-line finding, e.g. "<KEY> is not an app bug: <owner> returns/flags X">

*TL;DR:*
* <what fails, in one sentence>
* <why it is not the app: the app honors its inputs; the fault is <API/CMS/Backend/Data/Env>>
* <resolution or owner: fixed by <PR/ticket>, or "owned by <team>: needs <action>">

h3. Evidence (Charles sessions attached to this ticket)

|| Session || Build || <key flag / dimension> || <measured signal> ||
| <repro>  | <build> | <flag state> | *<value, e.g. 0>* |
| <working/fixed> | <build> | <flag state> | *<value, e.g. 6>* |

<one or two sentences reading the table: what the delta between sessions shows.>

h3. Root cause

{panel:title=🔴 <the broken path / wrong input>|borderColor=#DE350B|titleBGColor=#FFEBE6|bgColor=#FFF5F3}
{code:java}
<snippet or response fragment showing the fault>
{code}
{panel}

<explain why this produces the reported symptom, citing the exact field/flag/gate.>

h3. <Fix / Recommendation / Owner>

{panel:title=🟢 <the correct path, the fix, or the required upstream change>|borderColor=#006644|titleBGColor=#E3FCEF|bgColor=#F0FFF4}
{code:java}
<snippet of the fix, or the corrected config/response>
{code}
{panel}

<if fixed elsewhere: name the PR/ticket and branch. If not: state the owning team and the concrete action needed.>
