"""SessionStart: a new session begins in this repository.

Make sure storage exists; later, sweep for user edits made while no
session was running.
"""

from hooklib import storage


def handle(event):
    """Handle a parsed SessionStart payload."""
    print("handle SessionStart")
    if event["in_repo"]:
        storage.init(event["cwd"])
