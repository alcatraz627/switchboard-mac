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
  remote.py chatcmd <name>       the ssh line for a chat with its csync-assist; JSON {command}
  remote.py persist <name> on|off keep the host connected across reboots
  remote.py teardown <name>      end the session and clean the host
  remote.py forget <name>        drop a host or a pending invite
  remote.py invite <name>        mint an invite; JSON {ok, paste}
  remote.py fix                  csync doctor --fix
"""
import json
import os
import shlex
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
    tail = (r.stderr or r.stdout).strip()
    if len(tail) > 300:
        # Cut at a word, so the sentence does not start mid-word.
        tail = tail[-300:].split(" ", 1)[-1]
    try:
        obj = json.loads(r.stdout or "{}")
    except ValueError:
        return r.returncode, {"error": tail}
    # A failing csync that printed no JSON error still said why on stderr.
    if r.returncode != 0 and isinstance(obj, dict) and not obj.get("error") and tail:
        obj["error"] = tail
    return r.returncode, obj


SSH_CONFIG = os.path.expanduser("~/.config/csync/ssh_config")


def chat_command(name):
    """A terminal chat with csync-assist on the host: each line you type is one ask."""
    # No single quotes inside, so the copied line stays readable: ssh -t ... '<loop>'.
    loop = ('test -x ~/.local/bin/csync-assist || { echo "csync-assist is not installed on this host"; exit 1; }; '
            'echo "Chatting with csync-assist. Ctrl-D to leave."; '
            # printf then read, not read -p: the host's shell may be zsh, where -p means something else.
            'while printf "you> " && read -r m; do ~/.local/bin/csync-assist ask "$m"; echo; done')
    return f"ssh -t -F {shlex.quote(SSH_CONFIG)} csync-{shlex.quote(name)} '{loop}'"


def state():
    if not CSYNC:
        return {"installed": False, "checks": [], "hosts": []}
    code, st = csync("status", timeout=30)
    ls_code, ls = csync("ls", timeout=30)
    if not isinstance(st.get("checks"), list):
        # Show a broken console as a failing check rather than hiding the row.
        err = st.get("error")
        st["checks"] = [{"check": "csync status", "ok": False, "fix": None,
                         "detail": (err.get("message") if isinstance(err, dict) else err) or "csync status failed without saying why"}]
    if ls_code != 0 or not isinstance(ls.get("hosts") or {}, dict):
        # Without this a failed host list reads as "no hosts yet".
        err = ls.get("error")
        st["checks"] = list(st["checks"]) + [{"check": "csync ls", "ok": False, "fix": None,
            "detail": (err.get("message") if isinstance(err, dict) else err) or "csync ls failed without saying why"}]
        ls = {}
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
        fix = err.get("fix")
        err = (err.get("message") or err.get("detail") or json.dumps(err)) + (f" Fix: {fix}" if fix else "")
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
        code, obj = csync("shot", a[1], "--open", timeout=25)
        err = str(obj.get("error") or "")
        if "took longer" in err:
            # csync counts a host online while its tunnel process lives, even if the machine sleeps.
            obj["error"] = (f"{a[1]} did not answer within 25 s. It may be asleep or its connection dropped, "
                            "even though csync still shows it online.")
        elif "open X server" in err or "cannot open display" in err.lower():
            obj["error"] = f"{a[1]} has no screen to capture: it runs without a display."
        answer(code, obj)
    elif cmd == "chatcmd" and len(a) == 2:
        answer(0, {}, {"command": chat_command(a[1])})
    elif cmd == "persist" and len(a) == 3 and a[2] in ("on", "off"):
        answer(*csync("persist", a[1], a[2], timeout=60))
    elif cmd == "teardown" and len(a) == 2:
        answer(*csync("--yes", "teardown", a[1], timeout=120))
    elif cmd == "forget" and len(a) == 2:
        answer(*csync("--yes", "forget", a[1]))
    elif cmd == "invite" and len(a) == 2:
        code, obj = csync("invite", a[1])
        answer(code, obj, {"paste": obj.get("paste")})
    elif cmd == "fix":
        code, obj = csync("doctor", "--fix", timeout=120)
        checks = obj.get("checks")
        if not isinstance(checks, list):
            # No checks back means doctor did not finish; that is not a success.
            answer(1, {"error": obj.get("error") or "csync doctor did not report back"})
        failing = [c.get("check", "?") for c in checks if not c.get("ok")]
        answer(0 if not failing else 1, {"error": "still failing: " + ", ".join(failing) if failing else None})
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A crash answers in the helper's own shape, never a traceback.
        print(json.dumps({"ok": False, "error": f"Something went wrong with the remote hosts: {e}"}))
        sys.exit(1)
