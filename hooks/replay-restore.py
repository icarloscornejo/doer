#!/usr/bin/env python3
"""wk plugin: canonical REPLAY block stripper for skills/replay/SKILL.md.

Both hooks/replay-temp-commit-integrity-guard.sh (as a pre-commit invariant
check) and skills/replay/SKILL.md's cleanup fallback (as the actual removal
operation) call this SAME script, so "the check" and "the fallback" are
provably the same transformation instead of two hand-written copies that can
drift apart. See skills/replay/SKILL.md, "Injected code shape" section, the
restore-equality invariant.

A REPLAY block looks like:

    // REPLAY START <TAG>
    // REPLAY-ORIG:    val orders = api.getOrders(id)
        val forced = ...
    // REPLAY END <TAG>

restore() deletes every line between a REPLAY START and its matching REPLAY
END, except a REPLAY-ORIG line, which is unwrapped back to the original line
it preserved (everything after the "REPLAY-ORIG:" marker, byte for byte,
keeping that line's own original line-ending). Markers are detected as a
bare substring anywhere on the line, so this needs no per-language comment
syntax (works the same under "//", "#", or anything else).

This module works entirely on bytes (never decodes as text), and rebuilds
output using each input line's own line terminator (str.splitlines are not
used; bytes.splitlines(keepends=True) is), so CRLF vs LF and the presence or
absence of a final trailing newline survive the round trip unchanged. This
matters: a naive line-based text tool (awk in default mode, Python's text-mode
splitlines/join) silently normalizes exactly those things, which turns a
byte-for-byte equality check into a check that can pass on a corrupted file.

Usage:
  replay-restore.py check <post-image-file> <parent-file>
    Exit 0 if restore(post-image) == restore(parent), byte for byte.
    Exit 1 on a content mismatch (a real, non-replay change slipped in).
    Exit 2 on a structural violation (unbalanced or nested REPLAY
    START/END markers) in either file, or on an IO/usage error. In every
    case a one-line diagnostic goes to stderr.

  replay-restore.py strip <file>
    Print restore(file) to stdout, verbatim bytes, no trailing newline
    added or removed beyond what restore() itself produces. This IS
    cleanup's fallback operation: the caller writes stdout back over the
    file in place. Exit 2 with a diagnostic on a structural violation.
"""
import sys

START = b"REPLAY START"
END = b"REPLAY END"
ORIG = b"REPLAY-ORIG:"


class MarkerError(ValueError):
    pass


def restore(data: bytes) -> bytes:
    """Strip every REPLAY START..END block, keeping REPLAY-ORIG payloads."""
    out = []
    skip = False
    for raw in data.splitlines(keepends=True):
        # Strip only the line terminator for pattern matching; the
        # terminator itself is never inspected or altered.
        term_len = len(raw) - len(raw.rstrip(b"\r\n"))
        body = raw[: len(raw) - term_len] if term_len else raw
        term = raw[len(body):]

        if START in body:
            if skip:
                raise MarkerError("nested REPLAY START (a block was still open)")
            skip = True
            continue
        if END in body:
            if not skip:
                raise MarkerError("REPLAY END with no matching REPLAY START")
            skip = False
            continue
        if skip:
            if ORIG in body:
                idx = body.find(ORIG)
                orig_text = body[idx + len(ORIG):]
                out.append(orig_text + term)
            continue
        out.append(raw)

    if skip:
        raise MarkerError("REPLAY START with no matching REPLAY END")
    return b"".join(out)


def main(argv):
    if len(argv) < 2:
        print("usage: replay-restore.py check <post> <parent> | strip <file>", file=sys.stderr)
        return 2
    mode = argv[1]
    try:
        if mode == "strip":
            if len(argv) != 3:
                print("usage: replay-restore.py strip <file>", file=sys.stderr)
                return 2
            with open(argv[2], "rb") as f:
                data = f.read()
            sys.stdout.buffer.write(restore(data))
            return 0

        if mode == "check":
            if len(argv) != 4:
                print("usage: replay-restore.py check <post> <parent>", file=sys.stderr)
                return 2
            with open(argv[2], "rb") as f:
                post = restore(f.read())
            with open(argv[3], "rb") as f:
                parent = restore(f.read())
            if post == parent:
                return 0
            print(
                "restore-equality mismatch: post-image and parent differ "
                "after stripping REPLAY blocks (a non-replay change slipped in)",
                file=sys.stderr,
            )
            return 1

        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    except MarkerError as e:
        print(f"structural violation: {e}", file=sys.stderr)
        return 2
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
