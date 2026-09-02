"""Thin wrapper around the git commands the hooks need."""

import subprocess


def is_repo(cwd):
    """Whether cwd is inside an actual git working tree."""
    result = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


def diff(cwd, old_hash, new_hash):
    """Unified diff between two blobs in the object store ('' if identical)."""
    result = subprocess.run(
        ["git", "diff", "-b", old_hash, new_hash],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def store(cwd, path):
    """
    Creates a hash of the file and stores it in git's object storage.
    This allows us to easily compare versions later based on the hash.

    Warning: this will be GC'd by git over time!
    """
    result = subprocess.run(
        ["git", "hash-object", "-w", "--", str(path)],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()
