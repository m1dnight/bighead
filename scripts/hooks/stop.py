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
flushed to the JSONL *after* hooks return. The next turn's post carries it, at
its real uuid and its real position. A session's very last answer is the one
case that never arrives, and that is accepted.
"""

import json
import os
import sys
import urllib.parse
import urllib.request

BASE_URL = os.environ.get("MEM0_URL", "http://localhost:4001")
TIMEOUT_SECONDS = 5

# Transcript lines per request. Small enough that no single body is large — a
# line carrying a big tool result can be megabytes on its own — and large enough
# that a first backfill of a long session is a handful of requests rather than
# hundreds. Each chunk is stored before the next is sent, so a chunk that fails
# leaves every chunk before it stored and the next turn resumes from there.
CHUNK_LINES = 100


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

    payload["entries"] = chunk
    payload["transcript_length"] = len(chunk)
    payload["total_transcript_length"] = index + len(chunk)

    post("/hooks/backfill", payload)


def main():
    payload = json.load(sys.stdin)

    with open(payload["transcript_path"], encoding="utf-8") as transcript:
        entries = [decode(line) for line in transcript.read().splitlines()]

    seen = get(
        "/hooks/lines-seen",
        {"session_id": payload.get("session_id", ""), "cwd": payload.get("cwd", "")},
    )["lines_seen"]

    for index in range(seen, len(entries), CHUNK_LINES):
        send(payload, entries, index)

if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - see "Always exit 0" above
        pass

    sys.exit(0)
