#!/usr/bin/env bash
#
# Push every local Claude Code session transcript to the running Bighead
# server, straight from where Claude Code keeps them. Re-running is safe: the
# server dedups messages it has already stored.
#
# Usage: BIGHEAD_URL=http://localhost:4000 scripts/dev/import.sh

set -u

BIGHEAD_URL="${BIGHEAD_URL:-http://localhost:4000}"

# Where Claude Code keeps transcripts.
CLAUDE_DIR="$HOME/.claude"

# A session transcript is `projects/<project>/<session-uuid>.jsonl`. Every
# other `.jsonl` in the tree is not a conversation and is skipped:
# `history.jsonl`, `journal.jsonl`, and the `agent-*.jsonl` subagent logs
# under `<session>/subagents/`.
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# One request per session file. The body is the raw JSON Lines file, and the
# content type must not be `application/json`, or `Plug.Parsers` consumes the
# body before the controller sees it.
push_transcript() {
  local file="$1"
  printf '%s: ' "$file"
  curl -sS -X POST "$BIGHEAD_URL/v1/transcripts" \
    -H 'content-type: application/x-ndjson' \
    --data-binary @"$file" \
    -w ' (%{http_code})'
  echo
}

# Lists the session transcripts, one path per line.
session_transcripts() {
  find "$CLAUDE_DIR/projects" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' \
    | grep -E "/$UUID\.jsonl\$" \
    | sort
}

while IFS= read -r file; do
  push_transcript "$file"
done < <(session_transcripts)
