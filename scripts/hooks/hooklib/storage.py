"""Storage for the hook scripts, kept under <cwd>/.claude/mem0/."""

import json
from pathlib import Path

_SUBDIR = "mem0"


def init(cwd):
    """
    Create the storage directory if it does not exist.

    Safe to call on every hook invocation; existing content is untouched.
    Returns the storage directory.
    """
    directory = storage_dir(cwd)
    directory.mkdir(parents=True, exist_ok=True)

    return directory


def storage_dir(cwd):
    """The directory holding all hook storage for this repository."""
    return Path(cwd) / ".claude" / _SUBDIR


def append(path, record):
    """Append one record to a jsonl file as a single JSON line."""
    with Path(path).open("a") as f:
        f.write(json.dumps(record) + "\n")
