"""PostToolUse: Claude just wrote a file.

When the PostToolUse handler is invoked, it means the llm potentially modified a
file. We log this file here with its hash.
"""

from hooklib import diffs, drift


def handle(event):
    """Handle a parsed PostToolUse payload."""
    print("handle PostToolUse")
    # Diffing is all this handler does, and it needs a repo.
    if not event["in_repo"]:
        return

    # A shell command can touch any file, so look at the whole working tree.
    if event["tool"] == "Bash":
        drift.sweep(event["cwd"], "llm", event["session_id"], event["prompt_id"])
        return

    # Tool calls that do not target a file carry no file to check.
    if event["file"] is None:
        return

    file_path = event["file"]
    cwd = event["cwd"]
    session_id = event["session_id"]
    prompt_id = event["prompt_id"]

    diffs.detect_changes(cwd, file_path, "llm", session_id, prompt_id)
