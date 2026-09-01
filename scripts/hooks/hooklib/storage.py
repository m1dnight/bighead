"""Storage for the hook scripts, kept under <cwd>/.claude/mem0/."""

import json
from pathlib import Path

_FILES = ("payloads.jsonl",)

_SUBDIR = "mem0"


def init(cwd):
    """
    Create the storage directory and its jsonl files if they do not exist.

    Safe to call on every hook invocation; existing content is untouched.
    Returns the storage directory.
    """
    directory = storage_dir(cwd)
    directory.mkdir(parents=True, exist_ok=True)
    for name in _FILES:
        (directory / name).touch()

    return directory


def storage_dir(cwd):
    """The directory holding all hook storage for this repository."""
    return Path(cwd) / ".claude" / _SUBDIR


def payload_log(cwd):
    """Path of the payload log."""
    return storage_dir(cwd) / "payloads.jsonl"


def append(path, record):
    """Append one record to a jsonl file as a single JSON line."""
    with Path(path).open("a") as f:
        f.write(json.dumps(record) + "\n")
