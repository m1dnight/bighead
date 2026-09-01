"""Stop: the llm finished its turn.

Settle point: process the pending ledger changes into the change log.
"""

from hooklib import process


def handle(event):
    """Handle a parsed Stop payload."""
    print("handle Stop")
    process.run(event["cwd"])
