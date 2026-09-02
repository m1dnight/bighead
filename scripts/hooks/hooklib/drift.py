"""
Drift: when a user edits a file, we want to catch these changes at arbitrary
points in time.

Each file that is known to have changed in the datbase is looked at, and a new
diff is made vs the current version. If the version has changed, we know it was
a user edit and we store it as a diff made by the user.
"""

import os

from hooklib import git, repo


def sweep(cwd, session_id=None, prompt_id=None):
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
            repo.add_version(cwd, file_path, "user", hash, session_id, prompt_id)
        drifted.append(file_path)

    return drifted
