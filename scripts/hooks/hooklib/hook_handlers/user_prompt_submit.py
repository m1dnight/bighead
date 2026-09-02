"""UserPromptSubmit: the user typed a prompt and handed control back.

Post the transcript so far, then recall the stored facts closest to the
prompt and hand them back as context: whatever this handler returns is
written to the hook's real stdout, which Claude Code injects into the
session on a UserPromptSubmit.

Settle point: edits made between turns are the user's, so this is a good
moment to sweep claude-authored files for drift once that logic exists.
"""

from hooklib import client


def handle(event):
    """Handle a parsed UserPromptSubmit payload."""
    print("handle UserPromptSubmit")

    if event["transcript_path"]:
        client.post_transcript(event["transcript_path"])

    if not event["prompt"]:
        return None

    facts = client.recall(event["prompt"])
    if not facts:
        return None

    lines = "\n".join(f"- {fact}" for fact in facts)
    print(lines)
    return f"Relevant facts remembered from earlier sessions:\n{lines}\n"
