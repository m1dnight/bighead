"""Diffs between recorded versions of a file.

The ledger's interesting moments are the author transitions: a user
version followed by an llm version is what the llm changed, and an llm
version followed by a user version is what the user changed after the
llm was done. Two llm versions from different prompts count as well: the
later one is what the llm changed on the user's next instruction.
"""

import itertools
from pathlib import Path

from hooklib import git, repo

# edit
# file missing on disk?                        -> ignore
# not tracked before?                          -> new user version
# unchanged?                                   -> ignore
# changed?
#  -> user edit -> last entry by user          -> update
#               -> last enry by llm            -> new entry
#     llm edit  -> last entry llm, same prompt -> update
#               -> anything else               -> new entry
#
#
def detect_changes(cwd, file_path, version, session_id, prompt_id):
    """Detects if a file has changed, and stores changes accordingly."""

    if not _file_exists(cwd, file_path):
        return

    last = repo.last_version(cwd, file_path)
    hash = git.store(cwd, file_path)

    if not _file_tracked(cwd, file_path):
        _store_new_version(cwd, file_path, session_id, prompt_id, version, hash)
        return


    if last["hash"] == hash:
        return

    if version == "user":
        if last["version"] == "user":
            _update_hash(cwd, last["id"], hash, session_id)
        else:
            _store_new_version(cwd, file_path, session_id, prompt_id, version, hash)
    else:
        if last["version"] == "llm" and last["prompt_id"] == prompt_id:
            _update_hash(cwd, last["id"], hash, session_id)
        else:
            _store_new_version(cwd, file_path, session_id, prompt_id, version, hash)

    return


def _store_new_version(cwd, file_path, session_id, prompt_id, version, hash):
    repo.add_version(cwd, file_path, version, hash, session_id, prompt_id)

def _update_hash(cwd, id, hash, session_id):
    repo.replace_hash(cwd, id, hash, session_id)

def _file_exists(cwd, file_path):
    return (Path(cwd) / file_path).is_file()

def _file_tracked(cwd, file_path):
    return repo.last_version(cwd, file_path) is not None


def transitions(cwd, file_path):
    """One diff per author transition for a file, oldest first."""
    entries = repo.versions(cwd, file_path)

    found = []
    for before, after in itertools.pairwise(entries):
        # a run of same-author versions under one prompt is not a transition,
        # and identical hashes (e.g. a no-op edit) have nothing to diff
        if (
            before["version"] == after["version"]
            and before["prompt_id"] == after["prompt_id"]
        ):
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


def from_llm(cwd, file_path):
    """One diff per transition away from an llm version, oldest first.

    What replaced the llm's code: the user's hand edit, or the llm's own
    edit on the user's next prompt.
    """
    return [t for t in transitions(cwd, file_path) if t["from"]["version"] == "llm"]
