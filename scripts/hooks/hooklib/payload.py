"""Parse the JSON payload Claude Code pipes to hook scripts on stdin."""

import json

# Keys under which a tool's input names the file it touches.
_FILE_KEYS = ("file_path", "notebook_path")

_SUPPORTED_EVENTS = (
    "PreToolUse",
    "PostToolUse",
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "Stop",
)


def parse(raw):
    """
    Parse a raw hook payload into {event, file, cwd, session_id}.
    """
    payload = json.loads(raw)

    event = payload.get("hook_event_name")
    if event not in _SUPPORTED_EVENTS:
        return None

    return {
        "event": event,
        "file": _file_path(payload),
        "cwd": payload.get("cwd"),
        "session_id": payload.get("session_id"),
    }


def _file_path(payload):
    """The file the tool call is about, or None if there is none."""
    tool_input = payload.get("tool_input") or {}
    for key in _FILE_KEYS:
        if tool_input.get(key):
            return tool_input[key]

    return None
