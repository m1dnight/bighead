"""Stop: the llm finished its turn.

- Process the diffs of local changes.
- Post transcript.
"""

from hooklib import client, process, drift


def handle(event):
    """Handle a parsed Stop payload."""
    print("handle Stop")

    # The stop hook is called when an llm is done editing. So it will have
    # modified a bunch of files. The user might have edited some files in the
    # meantime too. If we do a sweep here, all the llm-touched files will
    # probably be in their llm-generated state, and all other changes will be
    # made by the user.
    drift.sweep(event["cwd"], "user", event["session_id"], event["prompt_id"])

    if event["transcript_path"]:
        client.post_transcript(event["transcript_path"])

    process.run(event["cwd"])
