"""Sqlite-backed ledger of file versions, kept in <cwd>/.claude/mem0/mem0.db.

Each row records "this file had this content hash, authored by user or
claude". The stdlib sqlite3 module is all this needs; WAL mode keeps
concurrent hook processes from stepping on each other.
"""

import sqlite3
from contextlib import closing

from . import storage

_SCHEMA = """
CREATE TABLE IF NOT EXISTS file_versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path TEXT NOT NULL,
    version TEXT NOT NULL,
    hash TEXT NOT NULL,
    session_id TEXT,
    prompt_id TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS file_versions_by_file ON file_versions (file_path, id);
"""


def connect(cwd):
    """Open the ledger database for this repository, creating it if needed."""
    conn = sqlite3.connect(storage.storage_dir(cwd) / "mem0.db")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(_SCHEMA)
    # ledgers created before prompt ids were recorded lack the column
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(file_versions)")}
    if "prompt_id" not in columns:
        conn.execute("ALTER TABLE file_versions ADD COLUMN prompt_id TEXT")
    return conn


def last_version(cwd, file_path):
    """The most recent entry for a file as a dict, or None if there is none."""
    with closing(connect(cwd)) as conn:
        row = conn.execute(
            "SELECT id, file_path, version, hash, session_id, prompt_id, created_at"
            " FROM file_versions WHERE file_path = ? ORDER BY id DESC LIMIT 1",
            (str(file_path),),
        ).fetchone()

    return dict(row) if row else None


def files(cwd):
    """All file paths that have recorded versions."""
    with closing(connect(cwd)) as conn:
        rows = conn.execute(
            "SELECT DISTINCT file_path FROM file_versions ORDER BY file_path"
        ).fetchall()

    return [row["file_path"] for row in rows]


def compact(cwd):
    """Keep only each file's latest entry, as the untouched baseline for
    later diffs; returns rows deleted."""
    with closing(connect(cwd)) as conn, conn:
        cursor = conn.execute(
            "DELETE FROM file_versions WHERE id NOT IN"
            " (SELECT MAX(id) FROM file_versions GROUP BY file_path)"
        )
        conn.execute("UPDATE file_versions SET version = 'untouched'")

    return cursor.rowcount


def versions(cwd, file_path):
    """All entries for a file as dicts, oldest first."""
    with closing(connect(cwd)) as conn:
        rows = conn.execute(
            "SELECT id, file_path, version, hash, session_id, prompt_id, created_at"
            " FROM file_versions WHERE file_path = ? ORDER BY id",
            (str(file_path),),
        ).fetchall()

    return [dict(row) for row in rows]


def replace_hash(cwd, version_id, file_hash, session_id=None):
    """Replace the hash (and session) of an existing entry in place."""
    with closing(connect(cwd)) as conn, conn:
        conn.execute(
            "UPDATE file_versions SET hash = ?, session_id = ? WHERE id = ?",
            (file_hash, session_id, version_id),
        )


def add_version(cwd, file_path, version, file_hash, session_id=None, prompt_id=None):
    """Append a new version entry for a file."""
    with closing(connect(cwd)) as conn, conn:
        conn.execute(
            "INSERT INTO file_versions (file_path, version, hash, session_id, prompt_id)"
            " VALUES (?, ?, ?, ?, ?)",
            (str(file_path), version, file_hash, session_id, prompt_id),
        )
