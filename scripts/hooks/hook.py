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
    if payload_dict == None:
        return

    # make sure it's a git repo, otherwise ignore
    if not git.is_repo(payload_dict["cwd"]):
        print("Not a .git repo, ignoring")
        return

    event = payload_dict["event"]
    HANDLERS[event](payload_dict)

    # debug logging, disable later
    cwd = payload_dict["cwd"]
    storage.append(storage.payload_log(cwd), raw_payload)


def main():
    raw_payload = sys.stdin.read()
    process(raw_payload)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
    sys.exit(0)
