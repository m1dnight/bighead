"""
Drift: when a user edits a file, we want to catch these changes at arbitrary
points in time.

Each file that is known to have changed in the datbase is looked at, and a new
diff is made vs the current version. If the version has changed, we know it was
a user edit and we store it as a diff made by the user.
"""

import os

from hooklib import git, repo, diffs


def sweep(cwd, version, session_id=None, prompt_id=None):
    """
    Looks over all the files in the git repo. If the file has changes versus the
    last time it was index, the change is chalked up to be a user's edit.
    """
    for file_path in repo.files(cwd):
        # a deleted file has nothing to hash; its last version stays as is
        if not os.path.isfile(file_path):
            continue

        diffs.detect_changes(cwd, file_path, version, session_id, prompt_id)
