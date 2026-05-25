# Debugging Protocol

Status: protocol shared by all skills in the `wk` plugin.

This protocol activates whenever Stage 4 or Stage 5 encounters a failing test, a runtime error, or any unexpected broken state. It is not a separate skill; it is a mandatory discipline the implementor and fixer subagents MUST follow before proposing any fix.

---

## Rule 0: No fix without root cause

**This is a hard rule with no exceptions.**

Do NOT propose, write, or apply any fix until the root cause is understood. Patching symptoms without understanding the cause produces new bugs and wastes iterations.

If the implementor cannot state the root cause in one concrete sentence ("X fails because Y"), it has not finished the investigation phase. It must not proceed to a fix.

---

## Phase 1: Root Cause Investigation

Before forming any hypothesis, the implementor MUST:

1. Parse the full error: message, stack trace, error code, and file/line references. Do not skim.
2. Reproduce the failure consistently. If it cannot be reproduced, narrate that and surface it as a blocker.
3. Trace data backward through the call chain from the failure point. Identify exactly where the value, state, or behavior diverges from what is expected.
4. For multi-component failures: instrument or log across component boundaries to isolate which boundary is corrupted.

Output of this phase: a single concrete sentence identifying the root cause.

---

## Phase 2: Pattern Analysis

Before forming a hypothesis, the implementor MUST compare the broken code against a working equivalent in the same codebase.

1. Locate similar code that performs the same operation and currently works.
2. Document EVERY difference between the working and broken versions. Not just the obvious ones. All of them.
3. Understand the prerequisites, configuration, and assumptions the working version relies on that the broken version may be missing.

Pattern analysis comes before hypothesis formation, not after. The delta between working and broken is the raw material for a sound hypothesis.

---

## Phase 3: Hypothesis and Testing

With root cause and pattern delta in hand:

1. State an explicit hypothesis: *"X causes the failure because Y, as evidenced by Z."* This sentence must be narrated before any change is made.
2. Make exactly one change to test the hypothesis. One variable at a time. Changing multiple things simultaneously invalidates the test.
3. Verify the result. If the hypothesis is wrong, return to Phase 1 and re-investigate. Do not stack additional changes on a failed hypothesis.

---

## Narration requirements

When this protocol activates, the implementor MUST narrate:

- Start of investigation: *"Root cause investigation: [error summary]."*
- Root cause conclusion: *"Root cause identified: [one sentence]."*
- Pattern analysis: *"Pattern analysis: comparing against [working reference]. Differences: [list]."*
- Hypothesis: *"Hypothesis: [explicit statement]."*
- Change: *"Applying single-variable change: [what and why]."*
- Result: *"Hypothesis [confirmed / refuted]. [next step]."*

Silent debugging is prohibited. The dev must always know where in the protocol the implementor is.

---

## When to invoke

Stage 4 and Stage 5 MUST invoke this protocol when any of the following occur:

- A test that was green turns red after a code change.
- A new test written in Stage 3 fails to pass after the implementation.
- A runtime error surfaces during on-device verification (Stage 6).
- The reviewer subagent identifies a blocker that indicates incorrect behavior (not just style).

The protocol does not apply to linter warnings, formatting issues, or non-behavioral suggestions.
