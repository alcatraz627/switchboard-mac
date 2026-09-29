#!/usr/bin/env python3
"""The other machines this Mac drives through csync: whether the console is
healthy (relay, Tailscale, Funnel), which hosts are connected or invited, and
the actions on them.

The Switchboard's Remote tab calls this. Every action is a csync verb, so the
terminal and the panel never disagree. Actions come from the owner clicking in
the panel, so they run as the human actor (CSYNC_ACTOR=human), which is how
csync records them in its audit log.

  remote.py list                 JSON {installed, checks, hosts}
  remote.py shot <name>          take a screenshot and open it
  remote.py shell <name>         open a Ghostty window with csync sh <name>
  remote.py teardown <name>      end the session and clean the host
  remote.py forget <name>        drop a host or a pending invite
  remote.py invite <name>        mint an invite; JSON {ok, paste}
  remote.py fix                  csync doctor --fix
"""
import json
import os
import shutil
import subprocess
import sys
import time

CANDIDATES = [os.path.expanduser("~/Code/Claude/csync/bin/csync"), os.path.expanduser("~/.local/bin/csync")]
CSYNC = next((p for p in CANDIDATES if os.path.exists(p)), shutil.which("csync"))


def csync(*args, timeout=60):
    env = dict(os.environ, CSYNC_ACTOR="human")
    try:
        r = subprocess.run([CSYNC, "--json", *args], capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 1, {"error": f"csync {args[0]} took longer than {timeout}s"}
    try:
        return r.returncode, json.loads(r.stdout or "{}")
    except ValueError:
        return r.returncode, {"error": (r.stderr or r.stdout).strip()[-300:]}


def state():
    if not CSYNC:
        return {"installed": False, "checks": [], "hosts": []}
    _, st = csync("status", timeout=30)
    _, ls = csync("ls", timeout=30)
    now = time.time()
    hosts = []
    for name, h in (ls.get("hosts") or {}).items():
        status = h.get("status") or "unknown"
        last = h.get("last_hello")
        # csync ls has already marked an online host offline when its hello
        # process is gone, so its status is trusted as is.
        if status == "invited" and (h.get("expires") or now) < now:
            status = "expired"
        hosts.append({
            "name": name,
            "status": status,
            "os": " ".join(x for x in (h.get("os_label"), h.get("osver")) if x),
            "user": h.get("user"),
            "last_seen": last,
            "expires": h.get("expires") if status == "invited" else None,
            "route": h.get("route_used") or h.get("route"),
        })
    order = {"online": 0, "invited": 1, "offline": 2, "expired": 3}
    hosts.sort(key=lambda h: (order.get(h["status"], 3), h["name"]))
    return {"installed": True, "checks": st.get("checks", []), "hosts": hosts}


def answer(code, obj, extra=None):
    ok = code == 0 and obj.get("ok", True) is not False
    err = obj.get("error")
    if isinstance(err, dict):
        err = err.get("message") or err.get("detail") or json.dumps(err)
    out = {"ok": ok, "error": None if ok else (err or "csync failed")}
    out.update(extra or {})
    print(json.dumps(out))
    sys.exit(0 if ok else 1)


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    if cmd == "list":
        print(json.dumps(state()))
        return
    if not CSYNC:
        answer(1, {"error": "csync is not installed"})
    if cmd == "shot" and len(a) == 2:
        answer(*csync("shot", a[1], "--open", timeout=60))
    elif cmd == "shell" and len(a) == 2:
        # Ghostty runs the command in a new window; csync sh is interactive, so it needs a terminal.
        r = subprocess.run(["open", "-na", "Ghostty.app", "--args", "-e", CSYNC, "sh", a[1]],
                           capture_output=True, text=True)
        answer(r.returncode, {"error": r.stderr.strip() or "could not open Ghostty"})
    elif cmd == "teardown" and len(a) == 2:
        answer(*csync("--yes", "teardown", a[1], timeout=120))
    elif cmd == "forget" and len(a) == 2:
        answer(*csync("--yes", "forget", a[1]))
    elif cmd == "invite" and len(a) == 2:
        code, obj = csync("invite", a[1])
        answer(code, obj, {"paste": obj.get("paste")})
    elif cmd == "fix":
        code, obj = csync("doctor", "--fix", timeout=120)
        failing = [c["check"] for c in obj.get("checks", []) if not c.get("ok")]
        answer(0 if not failing else 1, {"error": "still failing: " + ", ".join(failing) if failing else None})
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    main()
