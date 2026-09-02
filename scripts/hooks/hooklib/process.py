"""Process pending ledger changes into a durable change log.

Going file by file, every change still in the ledger becomes a diff posted
to the mem0 server and appended to changes.jsonl. The ledger is then
compacted down to each file's latest version, which stays behind as the
baseline for future diffs.
"""

from hooklib import client, diffs, repo, storage


def changes_log(cwd):
    """Path of the processed-changes log."""
    return storage.storage_dir(cwd) / "changes.jsonl"


def run(cwd):
    """Process all pending changes; returns the appended change records."""
    changes = []
    # Create a list of diffs based on what is known locally.
    for file_path in repo.files(cwd):
        changes.extend(diffs.transitions(cwd, file_path))

    # submit all diffs, but if theyre not all delivered, keep the log, and try
    # again later. server dedupes anyway.
    delivered = [client.post_diff(change) for change in changes]
    if not all(delivered):
        print(f"mem0 unreachable ({sum(delivered)}/{len(delivered)} delivered), keeping ledger")
        return []

    for change in changes:
        storage.append(changes_log(cwd), change)

    repo.compact(cwd)

    return changes
