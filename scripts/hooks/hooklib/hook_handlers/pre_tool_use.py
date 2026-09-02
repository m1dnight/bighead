"""PreToolUse handler

When the PreToolUse handler is invoked, it means the llm will attempt to edit a
file. This hook will take a hash of that file and store it in git's object
storage.

This version is assumed to be a user-modified version, so we can compare it with the llm-edited version
"""

from hooklib import git, repo, diffs


def handle(event):
    """Handle a parsed PreToolUse payload."""
    print("handle PreToolUse")
    # Tool calls that do not target a file (e.g. Bash) carry no file to check.
    if event["file"] is None:
        return

    file_path = event["file"]

    # pretooluse means the LLM will likely edit this file, so we look at the
    # current state. if it has changes since last time, we update them. So this
    # is basically a log of the version before the tool modifies it.
    cwd = event["cwd"]
    session_id = event["session_id"]
    prompt_id = event["prompt_id"]

    diffs.detect_changes(cwd, file_path, "user", session_id, prompt_id)
