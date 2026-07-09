# Debugging Protocol

Mandatory discipline for any agent (doer build loop, bugfix investigation, fixers) responding to a failing test, a runtime error, or any unexpected broken state. Not a separate skill; a precondition to proposing any fix.

## Rule 0: No fix without root cause

Hard rule, no exceptions. Do NOT propose, write, or apply any fix until the root cause is understood. Patching symptoms produces new bugs and wastes iterations. If the implementor cannot state the root cause in one concrete sentence ("X fails because Y"), the investigation is not finished.

## Phase 1: Root Cause Investigation

1. Parse the full error: message, stack trace, error code, file/line references. Do not skim.
2. Reproduce the failure consistently. If it cannot be reproduced, surface that as a blocker.
3. Trace data backward through the call chain from the failure point; identify exactly where the value, state, or behavior diverges from expectation.
4. For multi-component failures, instrument or log across component boundaries to isolate which boundary is corrupted.

Output: one concrete sentence identifying the root cause.

## Phase 2: Pattern Analysis

Before forming a hypothesis, compare the broken code against a working equivalent in the same codebase:

1. Locate similar code that performs the same operation and currently works.
2. Document EVERY difference between working and broken, not just the obvious ones.
3. Understand the prerequisites and assumptions the working version relies on that the broken one may be missing.

The delta between working and broken is the raw material for a sound hypothesis.

## Phase 3: Hypothesis and Testing

1. State an explicit hypothesis before any change: *"X causes the failure because Y, as evidenced by Z."*
2. Make exactly ONE change to test it. Changing multiple things at once invalidates the test.
3. Verify. If the hypothesis is wrong, return to Phase 1; do not stack additional changes on a failed hypothesis.

## Narration

Narrate each phase transition: investigation start, root cause conclusion, pattern delta, hypothesis, the single change, and the confirmed/refuted result. Silent debugging is prohibited.

The protocol does not apply to linter warnings, formatting, or non-behavioral suggestions.
