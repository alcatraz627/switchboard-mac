#!/usr/bin/env python3
"""Lets the owner answer Claude Code's permission prompts from Switchboard.

Claude Code runs this as a PermissionRequest hook just before it would ask in
the terminal. When the owner has switched it on (Switchboard > Settings >
Claude's permission prompts), it writes the request where Switchboard's
Approvals tab lists it, then waits for Approve or Deny. Nobody answering in
time, or the switch being off, leaves the normal terminal question in place.

Files, all under ~/.claude (SWITCHBOARD_ASK_ROOT moves them, for tests):
  .switchboard-answers-prompts            the switch; its text is the wait in seconds
  .permission-ask/<session>--<id>.json    the request Switchboard lists
  .permission-ask/<session>--<id>.approved / .denied   the owner's answer
"""
import json
import os
import signal
import sys
import time
import uuid

ROOT = os.environ.get("SWITCHBOARD_ASK_ROOT") or os.path.expanduser("~/.claude")
SWITCH = os.path.join(ROOT, ".switchboard-answers-prompts")
ASK_DIR = os.path.join(ROOT, ".permission-ask")
DEFAULT_WAIT = 120


def summary(tool, inp):
    """The request in a line a person reads: the command, the file, the address."""
    if not isinstance(inp, dict):
        return ""
    for key in ("command", "file_path", "url", "query", "description", "pattern", "path"):
        v = inp.get(key)
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:300]
    return ", ".join(f"{k}: {str(v)[:40]}" for k, v in list(inp.items())[:3])


def decide(behavior, message=""):
    d = {"behavior": behavior}
    if message:
        d["message"] = message
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": d}}))


def main():
    if not os.path.exists(SWITCH):
        return
    try:
        wait = max(5, min(600, int(open(SWITCH).read().strip() or DEFAULT_WAIT)))
    except (OSError, ValueError):
        wait = DEFAULT_WAIT
    try:
        req = json.load(sys.stdin)
    except ValueError:
        return
    # these modes never ask, so there is nothing for the owner to answer
    if req.get("permission_mode") in ("bypassPermissions", "dontAsk"):
        return
    sid = str(req.get("session_id") or "unknown")
    tool = str(req.get("tool_name") or "a tool")
    rid = uuid.uuid4().hex[:8]
    os.makedirs(ASK_DIR, exist_ok=True)
    base = os.path.join(ASK_DIR, f"{sid}--{rid}")
    files = [base + ".json", base + ".approved", base + ".denied"]

    def clean(*_):
        for f in files:
            try:
                os.remove(f)
            except OSError:
                pass
        if _:
            sys.exit(0)

    # Claude Code cancels a hook at its timeout; take the request down with it
    signal.signal(signal.SIGTERM, clean)
    with open(base + ".json.tmp", "w") as f:
        json.dump({"nonce": rid, "tool": tool, "what": summary(tool, req.get("tool_input")),
                   "cwd": req.get("cwd", ""), "session": sid, "ts": time.time(), "wait": wait}, f)
    os.replace(base + ".json.tmp", base + ".json")
    deadline = time.time() + wait
    try:
        while time.time() < deadline:
            if os.path.exists(base + ".approved"):
                decide("allow")
                return
            if os.path.exists(base + ".denied"):
                decide("deny", "The owner denied this from Switchboard. Do not retry it; carry on with the rest of the work.")
                return
            if not os.path.exists(base + ".json"):
                return   # taken down from the panel without an answer: ask in the terminal
            time.sleep(0.3)
    finally:
        clean()


if __name__ == "__main__":
    main()
