"""Diffs between recorded versions of a file.

Every file starts from an "untouched" baseline: its content at HEAD when
the ledger first sees it, or whatever was left behind by the last push.
Each later row is one side's change on top of the row before it: an llm
row is what the llm changed, a user row is what the user changed, and two
llm rows from different prompts are what the llm changed on the user's
next instruction.
"""

import itertools
from pathlib import Path

from hooklib import git, repo


# edit
# outside the repository, or missing on disk?  -> ignore
# not tracked before?                          -> untouched baseline from HEAD, then as below
# unchanged?                                   -> ignore
# changed?
#  -> user edit -> last entry by user          -> update
#               -> anything else               -> new entry
#     llm edit  -> last entry llm, same prompt -> update
#               -> anything else               -> new entry
def detect_changes(cwd, file_path, version, session_id, prompt_id):
    """Detects if a file has changed, and stores changes accordingly."""

    if not _inside(cwd, file_path) or not _file_exists(cwd, file_path):
        return

    last = repo.last_version(cwd, file_path)
    hash = git.store(cwd, file_path)

    if last is None:
        # First sight: the committed content is the baseline nobody has
        # touched yet, so the first edit by either side diffs against it.
        repo.add_version(cwd, file_path, "untouched", git.head_blob(cwd, file_path))
        last = repo.last_version(cwd, file_path)

    if last["hash"] == hash:
        return

    print(f"File change: {file_path}")
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


def _store_new_version(cwd, file_path, session_id, prompt_id, version, hash):
    print(f"Storing new version of {file_path}")
    repo.add_version(cwd, file_path, version, hash, session_id, prompt_id)


def _update_hash(cwd, id, hash, session_id):
    print(f"Updating hash of {id}")
    repo.replace_hash(cwd, id, hash, session_id)


def _inside(cwd, file_path):
    """Whether the file lives under cwd; anything else is not ours to track."""
    return (Path(cwd) / file_path).resolve().is_relative_to(Path(cwd).resolve())


def _file_exists(cwd, file_path):
    return (Path(cwd) / file_path).is_file()


def transitions(cwd, file_path):
    """One diff per consecutive pair of versions, oldest first.

    The ledger folds same-author edits under one prompt into one row, so
    every pair is one editor's change. Its origin says how the change came
    about: "manual" when the user edited by hand, "requested" when the llm
    changed its own code on the user's prompt, "agent" for any other llm
    edit.
    """
    entries = repo.versions(cwd, file_path)

    found = []
    for before, after in itertools.pairwise(entries):
        # a reformat-only edit hashes differently yet diffs to nothing
        diff = git.diff(cwd, before["hash"], after["hash"])
        if not diff.strip():
            continue

        # next version user                       -> manual: changed by hand
        # llm version -> next version llm         -> requested: changed on a prompt
        # untouched or user -> next version llm   -> agent: the llm's own work
        if after["version"] == "user":
            origin = "manual"
        elif before["version"] == "llm":
            origin = "requested"
        else:
            origin = "agent"

        found.append(
            {
                "file_path": file_path,
                "direction": f"{before['version']}_to_{after['version']}",
                "origin": origin,
                "from": before,
                "to": after,
                "diff": diff,
                "project": str(cwd),
                "session": after["session_id"],
            }
        )

    return found
