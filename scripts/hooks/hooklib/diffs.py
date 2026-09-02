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


def inspect(file_path, message):
    if (
        file_path
        == "/Users/christophe/Documents/Code/elixir/mem0/scripts/hooks/hooklib/diffs.py"
    ):
        print(message)


# edit
# outside the repository, or missing on disk?  -> ignore
# not tracked before?                          -> new entry, as the side recording it
# unchanged?                                   -> ignore
# changed?
#  -> user edit -> last entry by user          -> update
#               -> last entry by llm           -> new entry
#     llm edit  -> last entry llm, same prompt -> update
#               -> anything else               -> new entry
def detect_changes(cwd, file_path, version, session_id, prompt_id):
    """Detects if a file has changed, and stores changes accordingly."""

    if not _inside(cwd, file_path) or not _file_exists(cwd, file_path):
        inspect(file_path, "File is outside the repository or does not exist")
        return

    last = repo.last_version(cwd, file_path)
    hash = git.store(cwd, file_path)

    if last is None:
        print(f"First version of {file_path}")
        repo.add_version(cwd, file_path, version, hash, session_id, prompt_id)
        return

    if last["hash"] == hash:
        inspect(file_path, "File unchanged")
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
    about: "manual" when the user edited the llm's code by hand, "requested"
    when the llm changed its own code on the user's prompt, "agent" when
    the llm worked on the user's code.
    """
    entries = repo.versions(cwd, file_path)

    found = []
    for before, after in itertools.pairwise(entries):
        # a reformat-only edit hashes differently yet diffs to nothing
        diff = git.diff(cwd, before["hash"], after["hash"])
        if not diff.strip():
            continue

        # initial version llm  -> next version user -> manual: changed by hand
        #                      -> next version llm  -> requested: changed on a prompt
        # initial version user -> next version llm  -> agent: the llm's own work
        #                      -> next version user -> never: user rows fold
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
