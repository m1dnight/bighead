"""Thin HTTP client for the mem0 server."""

import json
import os
import urllib.request

BASE_URL = os.environ.get("MEM0_URL", "http://localhost:4001")

TIMEOUT_SECONDS = 5


def post_diff(change):
    """POST one ledger change to /v1/diffs; True when the server stored it."""
    body = {"file": str(change["file_path"]), "diff": change["diff"]}
    return _post("/v1/diffs", body)


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
