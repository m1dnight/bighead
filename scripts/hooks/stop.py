#!/usr/bin/env python3
"""Send the part of a Claude Code transcript mem0 does not have yet.

Runs as a `Stop` hook, which fires once when a turn is finished, so this is not
a hot path. It asks mem0 how many lines of this session it already has, sends
the rest in chunks, and keeps no state of its own — so a
session that started before mem0 was installed backfills on the next turn, a
turn whose post was lost is recovered by the one after it, and a backfill
interrupted halfway resumes from the last chunk that landed.

The line number is enough on its own because Claude Code only appends to a
transcript. Compaction writes a boundary entry and a summary and carries on in
the same file, so a line, once written, never moves.

Two invariants, both load-bearing:

  * **Write nothing to stdout.** A `Stop` hook that prints
    `{"decision": "block", ...}` sends Claude back to work instead of ending
    the turn. Silence is what lets the turn end.
  * **Always exit 0.** A non-zero exit blocks the stop the same way, with
    stderr as the reason. mem0 being down must not break a session.

The transcript is not complete when this runs: the assistant's final entry is
flushed to the JSONL after the answer itself completes. This waits briefly for
that write rather than accepting the gap — see `FLUSH_WAIT_SECONDS`. If it does
not land in time the transcript is sent one entry short, which is what happened
unconditionally before, and the next turn carries the entry anyway.
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request
import time

BASE_URL = os.environ.get("MEM0_URL", "http://localhost:4001")
TIMEOUT_SECONDS = 5

# Transcript lines per request. Small enough that no single body is large — a
# line carrying a big tool result can be megabytes on its own — and large enough
# that a first backfill of a long session is a handful of requests rather than
# hundreds. Each chunk is stored before the next is sent, so a chunk that fails
# leaves every chunk before it stored and the next turn resumes from there.
CHUNK_LINES = 100

# How long to wait for the answer this turn just produced to reach the file.
# It is written after the answer completes rather than with it: on a measured
# turn the entry was stamped 15:12:55.966, this hook started ~15:12:55.99, and
# the file it read still ended one entry short. Waiting is what lets mem0 have
# that entry with its real uuid at its real position — the thing a message
# rebuilt from `last_assistant_message` could not do, which is why rebuilding
# one was reverted (.plan/04-hook-ingress.md).
#
# Mid-session the wait is a convenience, because the next turn carries the entry
# anyway. For a session's *last* answer it is the only chance there will be.
FLUSH_WAIT_SECONDS = 2.0
FLUSH_POLL_SECONDS = 0.05


def decode(line):
    """One transcript line as JSON, or None if it cannot be read.

    The file is being appended to while it is read, so its last line can be
    torn. None holds that line's place: mem0 numbers messages by their position
    in the file, so dropping the line outright would shift every entry after it
    and store the same message twice under two numbers. mem0 discards entries it
    cannot recognise anyway.
    """
    try:
        return json.loads(line)
    except ValueError:
        return None


def read_entries(path):
    """Every line of the transcript as JSON, position preserved."""
    with open(path, encoding="utf-8") as transcript:
        return [decode(line) for line in transcript.read().splitlines()]


def holds(entries, message):
    """Has `message` reached one of these entries?

    Both sides are re-encoded before comparing, because inside an entry the
    answer is JSON — its newlines are two characters and its quotes are escaped
    — while `last_assistant_message` arrives as ordinary text. Encoding the
    needle the same way is what makes a substring search correct without
    walking each entry's content blocks to find the assistant's text.

    Comparing against the parsed entry rather than the raw file also means a
    line still mid-write does not count as arrived: it can already carry the
    answer without being valid JSON yet, and `decode` has turned those into
    None.
    """
    needle = json.dumps(message, ensure_ascii=False)[1:-1]

    return any(needle in json.dumps(entry, ensure_ascii=False) for entry in entries if entry)


def await_flush(path, message):
    """The transcript, having waited a moment for `message` to appear in it.

    Gives up at `FLUSH_WAIT_SECONDS` and returns what is there. The turn should
    not be held open on mem0's account, and the file is correct either way —
    just one entry short, the way it was before this waited at all.
    """
    deadline = time.monotonic() + FLUSH_WAIT_SECONDS
    entries = read_entries(path)

    while message and not holds(entries, message) and time.monotonic() < deadline:
        time.sleep(FLUSH_POLL_SECONDS)
        entries = read_entries(path)

    return entries


def get(path, params):
    url = BASE_URL + path + "?" + urllib.parse.urlencode(params)

    with urllib.request.urlopen(url, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def post(path, body):
    request = urllib.request.Request(
        BASE_URL + path,
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json"},
    )

    urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS).close()





def send(payload, entries, index):
    """Post the chunk of `entries` beginning at absolute line `index`.

    mem0 derives each entry's line number from the difference between the two
    lengths, so they describe where this chunk sits in the file rather than how
    long the file is. A chunk is therefore numbered from its real position, and
    the same chunk sent again lands on the same numbers.
    """
    chunk = entries[index : index + CHUNK_LINES]

    body = dict(payload)
    body["entries"] = chunk
    body["transcript_length"] = len(chunk)
    body["total_transcript_length"] = index + len(chunk)

    post("/hooks/backfill", body)


def main():
    payload = json.load(sys.stdin)

    entries = await_flush(
        payload["transcript_path"], payload.get("last_assistant_message")
    )

    seen = get(
        "/hooks/lines-seen",
        {"session_id": payload.get("session_id", ""), "cwd": payload.get("cwd", "")},
    )["lines_seen"]

    for index in range(seen, len(entries), CHUNK_LINES):
        send(payload, entries, index)

    # The Stop event itself, verbatim. Sent after backfill so that by the time
    # the server acts on it — checking whether the summary needs updating — the
    # messages of this turn are already stored.
    post("/hooks/stop", payload)

if __name__ == "__main__":
    try:
        time.sleep(1)
        main()
    except Exception:  # noqa: BLE001 - see "Always exit 0" above
        pass

    sys.exit(0)
