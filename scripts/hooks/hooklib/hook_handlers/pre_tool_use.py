"""PreToolUse handler

When the PreToolUse handler is invoked, it means the llm will attempt to edit a
file. This hook will take a hash of that file and store it in git's object
storage.

This version is assumed to be a user-modified version, so we can compare it with the llm-edited version
"""

from hooklib import git, repo


def handle(event):
    """Handle a parsed PreToolUse payload."""
    print("handle PreToolUse")
    # Tool calls that do not target a file (e.g. Bash) carry no file to check.
    if event["file"] is None:
        return

    file_path = event["file"]

    hash = git.store(event["cwd"], file_path)

    # mark the file as current version owned by the user, but only when the
    # content actually drifted from the last recorded version. If the last
    # version was a user version as well, just update its hash to reflect the
    # latest version.
    last = repo.last_version(event["cwd"], file_path)
    if last is not None and last["hash"] == hash:
        return
    if last is not None and last["version"] == "user":
        repo.replace_hash(event["cwd"], last["id"], hash, event["session_id"])
    else:
        repo.add_version(
            event["cwd"], file_path, "user", hash, event["session_id"], event["prompt_id"]
        )
