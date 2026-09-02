"""Thin HTTP client for the mem0 server."""

import json
import os
import urllib.request

BASE_URL = os.environ.get("MEM0_URL", "http://localhost:4001")

TIMEOUT_SECONDS = 5

# The transcript endpoint stores messages and extracts facts before replying,
# and the extraction is an LLM call — give it room the JSON posts don't need.
TRANSCRIPT_TIMEOUT_SECONDS = 60


def post_diff(change):
    """POST one ledger change to /v1/diffs; True when the server stored it."""
    body = {"file": str(change["file_path"]), "diff": change["diff"]}
    return _post("/v1/diffs", body)


def post_transcript(path):
    """POST a whole transcript file to /v1/transcripts as raw JSON Lines.

    The server dedups messages it has already stored, so posting the same
    file on every Stop is safe. True on a 2xx reply.
    """
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False

    request = urllib.request.Request(
        BASE_URL + "/v1/transcripts",
        data=data,
        headers={"content-type": "application/jsonl"},
    )
    try:
        with urllib.request.urlopen(
            request, timeout=TRANSCRIPT_TIMEOUT_SECONDS
        ) as response:
            print(response.read().decode())
        return True
    except OSError:
        return False


def recall(prompt):
    """POST the prompt to /v1/recall; the relevant fact texts, best first.

    Empty on any failure — a session must never be blocked because the
    memory server is down.
    """
    request = urllib.request.Request(
        BASE_URL + "/v1/recall",
        data=json.dumps({"prompt": prompt}).encode(),
        headers={"content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            reply = json.load(response)
    except (OSError, ValueError):
        return []

    return [fact["fact"] for fact in reply.get("facts", []) if fact.get("fact")]


def _post(path, body):
    """POST a JSON body; True on a 2xx reply, False on anything else."""
    request = urllib.request.Request(
        BASE_URL + path,
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
    )
    try:
        urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS).close()
        return True
    except OSError:
        return False
