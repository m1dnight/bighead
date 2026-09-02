"""
Drift: catch file changes made outside the Edit/Write tools at arbitrary
points in time.

Every file in the ledger, plus whatever git sees as modified or untracked, is
compared against its last recorded version. A change is stored as an edit by
`version`: "user" between tool calls, "llm" right after a shell command.
"""

from hooklib import diffs, git, repo


def sweep(cwd, version, session_id=None, prompt_id=None):
    """
    Looks over every known file. If the file has changes versus the last time it
    was indexed, the change is chalked up to `version`.
    """
    files = set(repo.files(cwd)) | set(git.changed_files(cwd))
    for file_path in sorted(files):
        diffs.detect_changes(cwd, file_path, version, session_id, prompt_id)
