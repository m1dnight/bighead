#!/usr/bin/env python3

import sys
import traceback

from hooklib import git, payload, storage
from hooklib.hook_handlers import (
    post_tool_use,
    pre_tool_use,
    session_end,
    session_start,
    stop,
    user_prompt_submit,
)

real_stdout = sys.stdout
sys.stdout = open("/tmp/log.txt", "a", buffering=1)
sys.stderr = open("/tmp/log.txt", "a", buffering=1)


HANDLERS = {
    "PreToolUse": pre_tool_use.handle,
    "PostToolUse": post_tool_use.handle,
    "SessionStart": session_start.handle,
    "SessionEnd": session_end.handle,
    "UserPromptSubmit": user_prompt_submit.handle,
    "Stop": stop.handle,
}


def process(raw_payload):
    payload_dict = payload.parse(raw_payload)

    # If the payload was None, we don't care about it.
    if payload_dict is None:
        return None

    # Without a git repo there is no baseline to diff against, so the handlers
    # skip the diffing work; the conversation itself is still tracked.
    payload_dict["in_repo"] = git.is_repo(payload_dict["cwd"])

    if payload_dict["in_repo"]:
        # A shell command can leave the session in a subdirectory, and the payload
        # reports that as cwd. The ledger and the changed-file paths both hang off
        # the repository root, so always work from there.
        payload_dict["cwd"] = git.toplevel(payload_dict["cwd"])

        # initialize storage if not yet done
        storage.init(payload_dict["cwd"])

    event = payload_dict["event"]
    result = HANDLERS[event](payload_dict)

    return result


def main():
    raw_payload = sys.stdin.read()
    result = process(raw_payload)

    # A handler's return value is for Claude Code, not the log: on
    # UserPromptSubmit whatever lands on stdout is injected as context.
    if result:
        real_stdout.write(result)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
    sys.exit(0)
