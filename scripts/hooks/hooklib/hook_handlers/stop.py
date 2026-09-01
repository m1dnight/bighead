"""Stop: the llm finished its turn.

- Process the diffs of local changes.
- Post transcript.
"""

from hooklib import client, process


def handle(event):
    """Handle a parsed Stop payload."""
    print("handle Stop")

    if event["transcript_path"]:
        client.post_transcript(event["transcript_path"])

    process.run(event["cwd"])
