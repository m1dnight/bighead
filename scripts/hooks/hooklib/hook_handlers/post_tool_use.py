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

    hash = git.store(event["cwd"], file_path)
    # if the previous version is an llm-generated one, and it also has the same
    # prompt id, it means it's just the llm editing the file (e.g., making sure
    # the tests pass etc).
    #
    # if the last change was a different prompt id, or it was a user, it's a
    # change we need to capture. it could be the user who made an edit, or a new
    # prompt telling the llm to make some change.
    last = repo.last_version(event["cwd"], file_path)
    if last is not None and last["version"] == "llm" and last["prompt_id"] == event["prompt_id"]:
        repo.replace_hash(event["cwd"], last["id"], hash, event["session_id"])
    else:
        repo.add_version(
            event["cwd"], file_path, "llm", hash, event["session_id"], event["prompt_id"]
        )

    changes = diffs.from_llm(event["cwd"], file_path)

    for change in changes:
        print(f"\n###---###\nChange: {change['diff']}\n###---###\n")