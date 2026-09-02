"""PostToolUse: Claude just wrote a file.

When the PostToolUse handler is invoked, it means the llm potentially modified a
file. We log this file here with its hash.
"""

from hooklib import git, repo, diffs


def handle(event):
    """Handle a parsed PostToolUse payload."""
    print("handle PostToolUse")
    # Tool calls that do not target a file (e.g. Bash) carry no file to check.
    if event["file"] is None:
        return

    file_path = event["file"]
    cwd = event["cwd"]
    session_id = event["session_id"]
    prompt_id = event["prompt_id"]

    diffs.detect_changes(cwd, file_path, "llm", session_id, prompt_id)
