#!/usr/bin/env bash
#
# Forwards a Claude Code `UserPromptSubmit` hook payload to mem0 exactly as it
# arrives.
#
# Nothing is inlined. The conversation reaches mem0 through
# `stop.sh`, which sees the same transcript, so all this event has
# to carry is the prompt someone just typed and the session it belongs to.
# `transcript_path` rides along in the payload as a path, never as content.
#
# stdout is deliberately *not* silenced here, unlike in the display hook: what
# curl writes is mem0's response, and Claude Code reads it as the hook
# response — `hookSpecificOutput.additionalContext` is how recalled memory gets
# appended to the prompt. So nothing else may ever be printed from this script.
#
# Always exits 0. A non-zero exit from a hook interrupts the session, so a mem0
# that is down has to be invisible.

set -uo pipefail

curl -sS --max-time 5 -X POST http://localhost:4001/hooks/user-prompt-submit \
  -H 'content-type: application/json' --data-binary @- 2>/dev/null

exit 0
