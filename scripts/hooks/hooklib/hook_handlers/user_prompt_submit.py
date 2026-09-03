"""UserPromptSubmit: the user typed a prompt and handed control back.

Post the transcript so far, then recall the stored facts closest to the
prompt and hand them back as context: whatever this handler returns is
written to the hook's real stdout, which Claude Code injects into the
session on a UserPromptSubmit.

Settle point: edits made between turns are the user's, so known files are
swept for drift first and any diffs that surfaces are pushed right away.
"""

from hooklib import client, drift, process


def handle(event):
    """Handle a parsed UserPromptSubmit payload."""
    print("handle UserPromptSubmit")

    # Some files may have changed in the meantime, and this hook is called most
    # often, so fire off a sweep now to catch any changes made in the meantime
    # by the user.
    if event["in_repo"]:
        drift.sweep(event["cwd"], "user", event["session_id"], event["prompt_id"])
        process.run(event["cwd"])

    if event["transcript_path"]:
        client.post_transcript(event["transcript_path"])

    if not event["prompt"]:
        return None

    facts = client.recall(event["prompt"])
    if not facts:
        return None

    lines = "\n".join(f"- {fact}" for fact in facts)

    return f"Relevant facts remembered from earlier sessions:\n{lines}\n"
