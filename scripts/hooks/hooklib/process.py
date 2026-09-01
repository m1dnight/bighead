"""Process pending ledger changes into a durable change log.

Going file by file, every author transition still in the ledger becomes
a diff appended to changes.jsonl. The ledger is then compacted down to
each file's latest version, which stays behind as the baseline for
future diffs.
"""

from hooklib import diffs, repo, storage


def changes_log(cwd):
    """Path of the processed-changes log."""
    return storage.storage_dir(cwd) / "changes.jsonl"


def run(cwd):
    """Process all pending changes; returns the appended change records."""
    print("Processing diffs")
    changes = []
    for file_path in repo.files(cwd):
        changes.extend(diffs.transitions(cwd, file_path))

    for change in changes:
        storage.append(changes_log(cwd), change)

    repo.compact(cwd)

    return changes
