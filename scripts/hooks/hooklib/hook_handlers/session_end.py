"""SessionEnd: the session is over.
"""

from hooklib import process


def handle(event):
    """Handle a parsed SessionEnd payload."""
    print("handle SessionEnd")
    process.run(event["cwd"])
