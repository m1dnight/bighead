"""Drift: user edits made while no tool call touched the file.

The ledger only learns of a file when a tool call is about to touch it
(PreToolUse) or just did (PostToolUse). A file the user edits by hand and
Claude never touches again would never get its llm -> user transition
recorded, so at a settle point every known file is rehashed and any that
drifted gets a user version.
"""

import os

from hooklib import git, repo


def sweep(cwd, session_id=None):
    """Record a user version for every known file whose content drifted.

    Consecutive user versions collapse into one holding the latest hash, so
    editing a file over several prompts still yields a single llm -> user
    diff from the last llm version to the latest content. Returns the paths
    that drifted.
    """
    drifted = []
    for file_path in repo.files(cwd):
        # a deleted file has nothing to hash; its last version stays as is
        if not os.path.isfile(file_path):
            continue

        last = repo.last_version(cwd, file_path)
        hash = git.store(cwd, file_path)
        if last["hash"] == hash:
            continue

        if last["version"] == "user":
            repo.replace_hash(cwd, last["id"], hash, session_id)
        else:
            repo.add_version(cwd, file_path, "user", hash, session_id)
        drifted.append(file_path)

    return drifted
