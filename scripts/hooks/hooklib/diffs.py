"""Diffs between recorded versions of a file.

The ledger's interesting moments are the author transitions: a user
version followed by an llm version is what the llm changed, and an llm
version followed by a user version is what the user changed after the
llm was done.
"""

import itertools

from hooklib import git, repo


def transitions(cwd, file_path):
    """One diff per author transition for a file, oldest first."""
    entries = repo.versions(cwd, file_path)

    found = []
    for before, after in itertools.pairwise(entries):
        # a run of same-author versions is not a transition, and identical
        # hashes (e.g. a no-op edit) have nothing to diff
        if before["version"] == after["version"]:
            continue
        if before["hash"] == after["hash"]:
            continue

        # the diff ignores whitespace, so a reformat-only edit hashes
        # differently yet diffs to nothing; the server rejects an empty
        # diff, and retrying it would keep the ledger from ever draining
        diff = git.diff(cwd, before["hash"], after["hash"])
        if not diff.strip():
            continue

        found.append(
            {
                "file_path": file_path,
                "direction": f"{before['version']}_to_{after['version']}",
                "from": before,
                "to": after,
                "diff": diff,
                "project": str(cwd),
                "session": after["session_id"],
            }
        )

    return found


def user_to_llm(cwd, file_path):
    """One diff per user -> llm transition for a file, oldest first."""
    return [t for t in transitions(cwd, file_path) if t["direction"] == "user_to_llm"]


def llm_to_user(cwd, file_path):
    """One diff per llm -> user transition for a file, oldest first."""
    return [t for t in transitions(cwd, file_path) if t["direction"] == "llm_to_user"]
