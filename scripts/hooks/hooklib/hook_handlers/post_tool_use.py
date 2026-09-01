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
    # consecutive llm versions collapse into one entry holding the latest hash.
    # Only if the last version was user-edited do we add a new version.
    last = repo.last_version(event["cwd"], file_path)
    if last is not None and last["version"] == "llm":
        repo.replace_hash(event["cwd"], last["id"], hash, event["session_id"])
    else:
        repo.add_version(event["cwd"], file_path, "llm", hash, event["session_id"])

    changes = diffs.llm_to_user(event["cwd"], file_path)

    for change in changes:
        print(f"\n###---###\nChange: {change['diff']}\n###---###\n")