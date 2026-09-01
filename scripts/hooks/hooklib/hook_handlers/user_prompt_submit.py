"""UserPromptSubmit: the user typed a prompt and handed control back.

Settle point: edits made between turns are the user's, so this is a good
moment to sweep claude-authored files for drift once that logic exists.
"""


def handle(event):
    """Handle a parsed UserPromptSubmit payload."""
    print("handle UserPromptSubmit")
