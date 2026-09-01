"""SessionEnd: the session is over.

 - Process the diffs of local changes.
 - Post transcript.
"""

from hooklib import client, process


def handle(event):
    """Handle a parsed SessionEnd payload."""
    print("handle SessionEnd")
    # Capture first, for the same reason as Stop: the diff pipeline can
    # raise, and its health must not cost us the conversation.
    if event["transcript_path"]:
        client.post_transcript(event["transcript_path"])

    process.run(event["cwd"])
