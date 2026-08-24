#!/usr/bin/env bash
#
# Forwards a Claude Code `Stop` hook payload to mem0 with the tail of the
# transcript appended: the payload carries `transcript_path`, never the
# messages themselves.
#
# `Stop` fires once, when a turn is finished — so unlike `MessageDisplay` this
# is not a hot path.
#
# **The transcript is not complete when this runs, and that is measured.** The
# assistant's final entry is flushed to the JSONL *after* the hook returns: on a
# real turn the entry was stamped 15:12:55.966, the hook started ~15:12:55.99
# and ran 63ms, and the file it read still ended one entry short. The stamp is
# message-completion time; the write is end-of-turn bookkeeping that happens
# after hooks. Every earlier entry is there — only the answer this turn just
# produced is missing.
#
# The payload closes that gap itself: `last_assistant_message` is exactly the
# text of the entry that has not landed. mem0 reconstructs a message from it,
# which is why `hook_at` below is sent.
#
# Usage: stop.sh [LIMIT]   — last LIMIT transcript lines, default 300.
#
# Two invariants, both load-bearing:
#
#   - **Write nothing to stdout.** A `Stop` hook that prints
#     `{"decision": "block", "reason": ...}` sends Claude back to work instead
#     of ending the turn, and `stop_hook_active` in the payload exists because
#     that is how the loop is detected. Silence is what lets the turn end.
#   - **Always exit 0.** Exit 2 blocks the stop the same way, with stderr as
#     the reason.
#
# The post is fired into the background with its stdio detached: mem0 has
# nothing to say here that Claude Code should act on, and a turn should not
# take longer to finish because mem0 is slow.

set -uo pipefail

limit="${1:-500}"

payload=$(cat)
transcript=$(jq -r '.transcript_path' <<<"$payload" 2>/dev/null)

# The transcript is JSONL: one entry per line, so the last N entries are the
# last N lines and no parsing is needed to find them. `tail` reads from the end
# and `wc` only counts bytes.
#
# Selecting *which* entries count as something someone said is therefore the
# receiver's job — this sends summaries, meta entries and tool results along
# with the rest, and mem0's normaliser already drops what it does not
# recognise.
lines=$(tail -n "$limit" "$transcript" 2>/dev/null) || lines=""

# Both counts must define "line" the same way, or the offset the receiver
# derives from them is wrong by one. `wc -l` counts newlines and `grep -c ''`
# counts lines including an unterminated last one — and the last line of a
# transcript being appended to right now is exactly the unterminated case. So
# both use `grep -c ''`.
total=$(grep -c '' "$transcript" 2>/dev/null) || total=0
sent=$(printf '%s' "$lines" | grep -c '')

# The two counts are what let the receiver number this batch absolutely: it is
# the last `transcript_length` lines of a file that is `total_transcript_length`
# long, so the first entry sent sits at line
# `total_transcript_length - transcript_length` of the run.
#
# Each line is already a JSON value, so joining them with commas is a JSON
# array; no encoder needed. The one thing this cannot rule out is a torn last
# line — the file is being appended to while it is read — which reaches mem0 as
# malformed JSON rather than as a truncated entry. Per the ingest rule, the
# receiver drops what it cannot read and never fails the request.
entries=$(printf '%s' "$lines" | tr '\n' ',')

# The moment the hook fired, and the only honest date for the answer that
# `last_assistant_message` carries: that entry is not in the file yet, so
# nothing in the batch witnesses when it was said. This is measured rather than
# invented — the message completed within ~100ms of this line running. Second
# precision, because BSD `date` has no sub-second format; `seq` is what orders
# messages anyway. If it is missing or unreadable mem0 drops the answer rather
# than dating it wrongly, and the next turn's tail carries it instead.
hook_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Textual splice onto the payload object rather than a re-encode: the payload
# is already JSON. A payload that is not an object is posted unchanged.
head=${payload%\}}
if [ "$head" = "$payload" ]; then
  body=$payload
else
  sep=,
  [ "${head: -1}" = "{" ] && sep=""
  body="${head}${sep}\"total_transcript_length\":${total:-0},\"transcript_length\":${sent},\"hook_at\":\"${hook_at}\",\"entries\":[${entries}]}"
fi

curl -sS --max-time 5 -X POST http://localhost:4001/hooks/stop \
  -H 'content-type: application/json' --data-binary "$body" \
  >/dev/null 2>&1 &

exit 0
