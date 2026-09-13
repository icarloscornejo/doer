#!/usr/bin/env python3
"""wk plugin: Stage 1 AC-graph operations for skills/doer/stages/01-ac.md
Step 5.5 ("AC self-review"). Operates on the scratch draft written by Step 5
at .doer/tickets/<TICKET-ID>/ac-draft.json (the Step 6 "ac" object shape),
never on metadata.json directly: the single-write rule applies to
metadata.json, not to this scratch file, which Step 6 folds in via
--slurpfile and then deletes.

Every write is atomic (tmp file + os.replace, never in-place), same
rationale as lib/helpers/metadata.sh. validate and render-table are
read-only and never touch the draft.

Usage:
  ac-graph.py validate <draft.json>
      Integrity pass (01-ac.md Step 5.5, "Deterministic integrity pass"):
      every O-N has exactly one disposition; every candidate_id,
      merge_into_candidate_id, and source_map reference resolves to a
      definition in the draft; C-N are unique; no merge chains (every
      merge_into_candidate_id points at an ACTIVE candidate); AC-N are
      contiguous and unique; in_scope matches the active candidates.
      Prints {"pass": bool, "violations": [...]}. Exit 0 pass, 1 fail,
      2 malformed JSON.

  ac-graph.py merge <draft.json> --finding <finding.json>
      Applies "Applying a merge" steps 1-4: replaces the survivor's text
      with the finding's survivor_text verbatim, marks the dropped
      candidate merged, flattens any inbound edges that pointed at the
      now-dropped candidate onto the new survivor, renumbers AC-N. Records
      survivor_prev_text, redirected_edges, and survivor_post_hash on the
      merged[] row (undo data for `split`). Resets fidelity to unreviewed
      on every source_map row that resolves to the survivor. Prints one
      summary line. Exit 0, or 1 with a diagnostic and the draft untouched.

  ac-graph.py split <draft.json> <C-N>
      Undoes a merge, but ONLY if the survivor has not changed since (a
      later merge, a dev edit, anything): compares the survivor's CURRENT
      text hash against the merge's own survivor_post_hash. Refuses (exit
      1, draft untouched) on a hash mismatch, or on a merge that predates
      this undo data (no survivor_post_hash recorded). On success:
      reactivates the dropped candidate, restores the survivor's prior
      text, re-points every redirected edge back to the reactivated
      candidate, renumbers, resets fidelity on both.

  ac-graph.py render-table <draft.json>
      Prints the "Ticket AC correspondence" markdown table (01-ac.md Step
      5.5) to stdout, one row per origins[] entry across every O-N in
      ticket order, plus a final "ATTENTION <n> <obligation_ids>" line.
      Read-only.
"""
import hashlib
import json
import os
import sys


def load_draft(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_draft(path, draft):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(draft, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def _candidate_by_id(draft, cid):
    for c in draft.get("candidates", []):
        if c.get("candidate_id") == cid:
            return c
    return None


def _merged_entry_for(draft, cid):
    for m in draft.get("merged", []):
        if m.get("candidate_id") == cid:
            return m
    return None


def _resolve_survivor(draft, cid, _seen=None):
    """Follows merge_into_candidate_id hops from cid until landing on an
    active candidate (or cid itself, if it already is one). Guards against
    a cycle (should never happen under the flatten-edges invariant, but a
    malformed draft should not hang this script)."""
    seen = _seen or set()
    if cid in seen:
        return cid
    seen.add(cid)
    c = _candidate_by_id(draft, cid)
    if c is None:
        return cid
    if c.get("status") != "merged":
        return cid
    m = _merged_entry_for(draft, cid)
    if m is None:
        return cid
    return _resolve_survivor(draft, m.get("merge_into_candidate_id"), seen)


# ---------------------------------------------------------------- validate

def _validate(draft):
    violations = []

    candidates = draft.get("candidates", [])
    cids = [c.get("candidate_id") for c in candidates]
    dupes = {c for c in cids if cids.count(c) > 1}
    if dupes:
        violations.append(f"duplicate candidate_id(s): {sorted(dupes)}")

    active = [c for c in candidates if c.get("status") == "active"]
    merged_candidates = [c for c in candidates if c.get("status") == "merged"]

    acs = [c.get("ac") for c in active]
    if any(a is None for a in acs):
        violations.append("an active candidate has ac == null")
    ac_nums = sorted(
        int(a.split("-", 1)[1]) for a in acs if isinstance(a, str) and a.startswith("AC-")
    )
    expected = list(range(1, len(ac_nums) + 1))
    if ac_nums != expected:
        violations.append(f"AC-N not contiguous/unique: found {ac_nums}, expected {expected}")

    oos_ids = {o.get("id") for o in draft.get("out_of_scope", [])}
    q_ids = {q.get("id") for q in draft.get("open_questions_resolved", [])}

    for m in draft.get("merged", []):
        target = m.get("merge_into_candidate_id")
        target_c = _candidate_by_id(draft, target)
        if target_c is None:
            violations.append(f"merged[] entry {m.get('candidate_id')!r} targets unknown candidate {target!r}")
        elif target_c.get("status") != "active":
            violations.append(
                f"merge chain: {m.get('candidate_id')!r} merges into {target!r}, "
                f"which is not active (status={target_c.get('status')!r})"
            )
        src_c = _candidate_by_id(draft, m.get("candidate_id"))
        if src_c is None:
            violations.append(f"merged[] entry references unknown candidate_id {m.get('candidate_id')!r}")
        elif src_c.get("status") != "merged":
            violations.append(
                f"merged[] entry {m.get('candidate_id')!r} exists but the candidate's own status is "
                f"{src_c.get('status')!r}, not 'merged'"
            )

    for c in merged_candidates:
        if _merged_entry_for(draft, c.get("candidate_id")) is None:
            violations.append(f"candidate {c.get('candidate_id')!r} is status=merged but has no merged[] entry")

    seen_obligations = set()
    for row in draft.get("source_map", []):
        oid = row.get("obligation_id")
        if oid in seen_obligations:
            violations.append(f"duplicate source_map row for {oid!r}")
        seen_obligations.add(oid)
        disp = row.get("disposition") or {}
        dtype = disp.get("type")
        if dtype == "not_covered":
            continue
        ref = disp.get("ref")
        if dtype == "ac":
            if _candidate_by_id(draft, ref) is None:
                violations.append(f"{oid}: disposition.ref {ref!r} does not resolve to any candidate")
        elif dtype == "out_of_scope":
            if ref not in oos_ids:
                violations.append(f"{oid}: disposition.ref {ref!r} does not resolve to any out_of_scope entry")
        elif dtype == "open_question":
            if ref not in q_ids:
                violations.append(f"{oid}: disposition.ref {ref!r} does not resolve to any open_questions_resolved entry")
        else:
            violations.append(f"{oid}: unknown disposition.type {dtype!r}")

    expected_in_scope = [f"{c.get('ac')}: {c.get('text')}" for c in active]
    # active candidates are compared as a set against in_scope, since
    # candidates[] order (creation order) need not match in_scope's own
    # AC-N order after a renumber that this validate call precedes.
    if sorted(draft.get("in_scope", [])) != sorted(expected_in_scope):
        violations.append("in_scope does not match the active candidates' \"<AC-N>: <text>\" strings")

    return violations


def cmd_validate(argv):
    if len(argv) != 1:
        print("usage: ac-graph.py validate <draft.json>", file=sys.stderr)
        return 2
    try:
        draft = load_draft(argv[0])
    except json.JSONDecodeError as e:
        print(json.dumps({"pass": False, "violations": [f"malformed JSON: {e}"]}))
        return 2
    violations = _validate(draft)
    print(json.dumps({"pass": len(violations) == 0, "violations": violations}))
    return 0 if not violations else 1


# ------------------------------------------------------------------ renumber

def _renumber(draft):
    active = [c for c in draft.get("candidates", []) if c.get("status") == "active"]
    for i, c in enumerate(active, start=1):
        c["ac"] = f"AC-{i}"
    draft["in_scope"] = [f"{c['ac']}: {c['text']}" for c in active]
    ac_by_cid = {c["candidate_id"]: c["ac"] for c in active}
    for m in draft.get("merged", []):
        survivor = _resolve_survivor(draft, m.get("merge_into_candidate_id"))
        m["merged_into_ac"] = ac_by_cid.get(survivor)
    return draft


# --------------------------------------------------------------------- merge

def _reset_fidelity_for(draft, cid, note):
    n = 0
    for row in draft.get("source_map", []):
        disp = row.get("disposition") or {}
        if disp.get("type") != "ac":
            continue
        if _resolve_survivor(draft, disp.get("ref")) == cid:
            row["fidelity"] = {"verdict": "unreviewed", "note": note}
            n += 1
    return n


def cmd_merge(argv):
    draft_path = None
    finding_path = None
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--finding":
            finding_path = argv[i + 1]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 1 or finding_path is None:
        print("usage: ac-graph.py merge <draft.json> --finding <finding.json>", file=sys.stderr)
        return 2
    draft_path = args[0]
    draft = load_draft(draft_path)
    with open(finding_path, "r", encoding="utf-8") as f:
        finding = json.load(f)

    dropped_id = finding.get("candidate_id")
    survivor_id = finding.get("merge_into_candidate_id")
    survivor_text = finding.get("survivor_text")
    if not dropped_id or not survivor_id or survivor_text is None:
        print("error: finding must have candidate_id, merge_into_candidate_id, and survivor_text", file=sys.stderr)
        return 1

    dropped = _candidate_by_id(draft, dropped_id)
    survivor = _candidate_by_id(draft, survivor_id)
    if dropped is None or survivor is None:
        print(f"error: candidate_id or merge_into_candidate_id not found ({dropped_id!r}, {survivor_id!r})", file=sys.stderr)
        return 1
    if dropped.get("status") != "active" or survivor.get("status") != "active":
        print("error: both candidates must be active before merging", file=sys.stderr)
        return 1

    # Step 3: flatten inbound edges BEFORE step 1 overwrites the survivor's
    # text, so redirected_edges (below) reflects the pre-merge graph.
    redirected = []
    for m in draft.get("merged", []):
        if m.get("merge_into_candidate_id") == dropped_id:
            m["merge_into_candidate_id"] = survivor_id
            redirected.append(m.get("candidate_id"))

    # Step 1 (and undo data for `split`).
    survivor_prev_text = survivor.get("text")
    survivor["text"] = survivor_text

    # Step 2.
    dropped_text = dropped.get("text")
    dropped["status"] = "merged"
    dropped["ac"] = None

    draft.setdefault("merged", []).append(
        {
            "candidate_id": dropped_id,
            "merge_into_candidate_id": survivor_id,
            "merged_into_ac": None,  # recomputed by renumber, below
            "dropped": dropped_text,
            "reason": finding.get("explain") or finding.get("title") or "",
            "survivor_prev_text": survivor_prev_text,
            "redirected_edges": redirected,
            "survivor_post_hash": hashlib.sha256(survivor_text.encode("utf-8")).hexdigest(),
        }
    )

    # Step 4.
    _renumber(draft)

    n = _reset_fidelity_for(draft, survivor_id, f"merged {dropped_id}")

    save_draft(draft_path, draft)
    print(f"merged {dropped_id} -> {survivor_id} ({survivor['ac']}); fidelity reset on {n} row(s)")
    return 0


# --------------------------------------------------------------------- split

def cmd_split(argv):
    if len(argv) != 2:
        print("usage: ac-graph.py split <draft.json> <C-N>", file=sys.stderr)
        return 2
    draft_path, cid = argv
    draft = load_draft(draft_path)

    entry = _merged_entry_for(draft, cid)
    if entry is None:
        print(f"error: {cid!r} is not a merged candidate", file=sys.stderr)
        return 1
    if "survivor_prev_text" not in entry or "survivor_post_hash" not in entry:
        print(f"split refused: merge of {cid!r} predates undo data, edit by hand", file=sys.stderr)
        return 1

    survivor_id = entry["merge_into_candidate_id"]
    survivor = _candidate_by_id(draft, survivor_id)
    if survivor is None:
        print(f"error: survivor {survivor_id!r} not found", file=sys.stderr)
        return 1
    current_hash = hashlib.sha256(survivor.get("text", "").encode("utf-8")).hexdigest()
    if current_hash != entry["survivor_post_hash"]:
        print(
            f"split refused: survivor {survivor_id!r} changed since this merge, edit by hand",
            file=sys.stderr,
        )
        return 1

    dropped = _candidate_by_id(draft, cid)
    if dropped is None:
        print(f"error: candidate {cid!r} not found", file=sys.stderr)
        return 1

    dropped["status"] = "active"
    dropped["text"] = entry["dropped"]
    survivor["text"] = entry["survivor_prev_text"]

    for redirected_cid in entry.get("redirected_edges", []):
        redirected_entry = _merged_entry_for(draft, redirected_cid)
        if redirected_entry is not None:
            redirected_entry["merge_into_candidate_id"] = cid

    draft["merged"] = [m for m in draft.get("merged", []) if m.get("candidate_id") != cid]

    _renumber(draft)

    n = _reset_fidelity_for(draft, cid, f"split from {survivor_id}")
    n += _reset_fidelity_for(draft, survivor_id, f"split {cid} back out")

    save_draft(draft_path, draft)
    print(f"split {cid} back out of {survivor_id} ({dropped['ac']}); fidelity reset on {n} row(s)")
    return 0


# --------------------------------------------------------------- render-table

def _escape_cell(text):
    if text is None:
        text = ""
    text = str(text).replace("|", "\\|")
    return " ".join(text.split())


def _landed_in(draft, disp):
    dtype = disp.get("type")
    if dtype == "ac":
        survivor_id = _resolve_survivor(draft, disp.get("ref"))
        c = _candidate_by_id(draft, survivor_id)
        return c.get("ac") if c else disp.get("ref")
    if dtype in ("out_of_scope", "open_question", "not_covered"):
        return disp.get("ref") or "not_covered"
    return str(dtype)


_AC_SECTION_PREFIX = "Acceptance Criteria"


def cmd_render_table(argv):
    if len(argv) != 1:
        print("usage: ac-graph.py render-table <draft.json>", file=sys.stderr)
        return 2
    draft = load_draft(argv[0])

    rows = []
    attention_ids = []
    for row in draft.get("source_map", []):
        oid = row.get("obligation_id")
        disp = row.get("disposition") or {}
        fidelity = row.get("fidelity") or {}
        added_by = row.get("added_by")
        origins = row.get("origins") or []
        landed = _landed_in(draft, disp)

        if not origins:
            verdict = "unreviewed"
            table_rows_for_origin = [("(persisted text, not a ticket quote)", "unknown", landed, verdict)]
        else:
            verdict = fidelity.get("verdict", "unreviewed") if disp.get("type") == "ac" else None
            if disp.get("type") == "not_covered":
                verdict = "unreviewed"
            table_rows_for_origin = [
                (o.get("bullet", ""), o.get("section", ""), landed, verdict) for o in origins
            ]

        needs_attention = False
        for bullet, section, landed_in, verdict in table_rows_for_origin:
            fid_display = verdict if verdict is not None else "n/a (out of scope)" if disp.get("type") == "out_of_scope" else (verdict or "")
            if disp.get("type") == "out_of_scope":
                fid_display = "n/a (out of scope)"
            elif disp.get("type") == "open_question":
                fid_display = fid_display or "n/a (open question)"
            if added_by:
                suffix = f" (added by dev edit)" if added_by == "dev edit" else f" (added by {added_by})"
                fid_display = f"{fid_display}{suffix}"
            rows.append((bullet, section, landed_in, fid_display))
            if verdict in ("partial", "diverges", "unreviewed"):
                needs_attention = True
            if section.startswith(_AC_SECTION_PREFIX) and disp.get("type") in ("out_of_scope", "open_question", "not_covered"):
                needs_attention = True
        if needs_attention:
            attention_ids.append(oid)

    out = ["**Ticket AC correspondence**", ""]
    out.append("| Ticket bullet | Section | Landed in | Fidelity |")
    out.append("|---|---|---|---|")
    for bullet, section, landed_in, fid in rows:
        out.append(
            f'| "{_escape_cell(bullet)}" | {_escape_cell(section)} | {_escape_cell(landed_in)} | {_escape_cell(fid)} |'
        )
    print("\n".join(out))
    print(f"ATTENTION {len(attention_ids)} {' '.join(attention_ids)}".rstrip())
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    mode = argv[1]
    handlers = {
        "validate": cmd_validate,
        "merge": cmd_merge,
        "split": cmd_split,
        "render-table": cmd_render_table,
    }
    handler = handlers.get(mode)
    if handler is None:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    try:
        return handler(argv[2:])
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as e:
        print(f"error: malformed JSON: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
