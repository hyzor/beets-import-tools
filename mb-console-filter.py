#!/usr/bin/env python3
"""Tee beets' console output to the import log and hide its tracebacks.

Usage (from mb-import-lib.sh):

    PYTHONUNBUFFERED=1 beet -v import "$folder" 2>&1 \\
        | python3 mb-console-filter.py <logfile>

Two jobs, both of which must happen as the bytes arrive:

1. **Log everything, raw.** Every byte read is appended to <logfile> straight
   away, so the transcript is complete and current even if beets is killed
   while sitting at a prompt.

2. **Filter tracebacks out of the console.** On a failed MusicBrainz lookup
   beets logs one concise line plus a ~100-line urllib3/requests stack, then
   continues to its prompt. The stack belongs in the log, not on the screen.

Why this is a byte-stream filter and not `tee | awk`: any line-oriented tool
(awk, sed, grep) can only emit a record once it has seen the terminating
newline. beets' interactive prompt is the last thing written before beets
blocks on stdin, it wraps onto two lines, and it ends with `end=" "` — no
trailing newline:

    ➜ [S]kip, Use as-is, as Tracks, Group albums, Rescan directory,\\nEnter search, enter Id, aBort?␠

so with a line-oriented filter the whole tail after the last newline stays in
that tool's buffer and the screen shows a truncated prompt (the "enter Id"
option appears to be missing) until you answer it. Silent output loss on an
interactive prompt is exactly what made the wrapper look broken, so this
filter writes through immediately and only ever holds bytes that could still
turn out to be the start of a traceback header.
"""

import os
import re
import sys

TB_HEADER = b"Traceback (most recent call last):"
CHAIN_MARKERS = (
    b"During handling of the above exception, another exception occurred:",
    b"The above exception was the direct cause of the following exception:",
)
# ANSI colour/erase codes — stripped for matching only, never from output.
ANSI_RE = re.compile(rb"\x1b\[[0-9;]*[mK]")
# Exception summary lines such as "urllib3.exceptions.MaxRetryError: ...".
EXC_RE = re.compile(
    rb"^(?:.*\.)?[A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Timeout)(?:\(|:)"
)


def is_traceback_noise(line: bytes) -> bool:
    """Is this line part of a Python traceback dump (blank, frame, source
    line, exception-chain marker or exception summary)?"""
    s = ANSI_RE.sub(b"", line)
    if not s.strip():
        return True
    if s[:1] in (b" ", b"\t"):
        return True
    if s in CHAIN_MARKERS or s == TB_HEADER:
        return True
    return bool(EXC_RE.match(s))


def main() -> int:
    log_path = sys.argv[1] if len(sys.argv) > 1 else None
    log_fd = (
        os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        if log_path
        else None
    )

    pending = b""
    in_tb = False

    def emit(data: bytes) -> None:
        if data:
            os.write(1, data)

    try:
        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                break
            if log_fd is not None:
                os.write(log_fd, chunk)  # raw transcript, no buffering

            pending += chunk

            # Drain every complete line in the buffer. This must be a single
            # loop that keeps going until no newline is left: stopping at a
            # block boundary (`break`) would leave the rest of the chunk
            # unprocessed, and anything still buffered at EOF would be lost.
            while True:
                nl = pending.find(b"\n")
                if nl == -1:
                    break
                line, pending = pending[:nl], pending[nl + 1 :]

                if in_tb:
                    if is_traceback_noise(line):
                        continue  # still inside the dump
                    in_tb = False  # first non-dump line ends it; show it
                elif line == TB_HEADER:
                    in_tb = True  # a dump starts here; hide it
                    continue

                emit(line + b"\n")

            if not in_tb and pending and not TB_HEADER.startswith(pending):
                # A partial line that cannot become a traceback header: this
                # is the normal case for the wrapped prompt tail, so show it
                # right away instead of waiting for a newline that will not
                # arrive until the user answers the prompt.
                emit(pending)
                pending = b""

        # stdin closed (beets exited): flush a trailing partial line unless it
        # belongs to a dump that was still being suppressed.
        if pending and not (in_tb and is_traceback_noise(pending)):
            emit(pending)
    except BrokenPipeError:
        pass
    finally:
        if log_fd is not None:
            os.close(log_fd)

    return 0


if __name__ == "__main__":
    sys.exit(main())
