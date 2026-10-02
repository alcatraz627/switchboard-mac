#!/usr/bin/env python3
"""Whether a pm2 service comes back by itself after a restart of the Mac, and
the switch that changes it for one service without touching any other.

At login pm2's own agent runs `pm2 resurrect`, which restores the saved list in
~/.pm2/dump.pm2: an entry saved as "stopped" comes back stopped, any other
entry is started (pm2 lib/God.js, prepare). So the answer is read from that
file, never from a stored preference. `pm2 save` is never run: it would rewrite
every other service's entry to whatever state it happens to be in now.

  pm2login.py get <name>...        JSON {"agent": bool, "services": {name: bool}}
  pm2login.py set <name> on|off    JSON {ok} or {ok: false, error}

PM2_HOME moves the pm2 folder (tests use a scratch one).
"""
import json
import os
import subprocess
import sys
import tempfile

PM2_HOME = os.environ.get("PM2_HOME") or os.path.expanduser("~/.pm2")
DUMP = os.path.join(PM2_HOME, "dump.pm2")
BACKUP = DUMP + ".bak"
# The keys pm2 drops from a process when it saves one (lib/API/Startup.js, dump).
UNSAVED = ("instances", "pm_id", "prev_restart_delay")


def out(obj, code=0):
    print(json.dumps(obj))
    sys.exit(code)


def read_dump():
    """The saved list; [] when there is none yet. Raises on a damaged file."""
    if not os.path.exists(DUMP):
        return []
    with open(DUMP) as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError("the pm2 saved list is not a list")
    return data


def agent_installed():
    """pm2's login agent is what reads the saved list; without it nothing comes back."""
    if os.environ.get("PM2LOGIN_AGENT"):   # tests say yes or no instead of asking launchd
        return os.environ["PM2LOGIN_AGENT"] == "1"
    return os.path.exists(os.path.expanduser(f"~/Library/LaunchAgents/pm2.{os.environ.get('USER', '')}.plist"))


def live_entry(name):
    """The running process's pm2 settings, in the shape pm2 saves, or None."""
    try:
        r = subprocess.run(["pm2", "jlist"], capture_output=True, text=True, timeout=20)
        procs = json.loads(r.stdout or "[]")
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    for p in procs:
        env = p.get("pm2_env") or {}
        if env.get("name") == name:
            return {k: v for k, v in env.items() if k not in UNSAVED}
    return None


def write_dump(data):
    """Backs up the old list as pm2 does, then replaces it in one step."""
    if os.path.exists(DUMP):
        with open(DUMP, "rb") as src, open(BACKUP, "wb") as dst:
            dst.write(src.read())
    fd, tmp = tempfile.mkstemp(dir=PM2_HOME, prefix=".dump-")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, DUMP)


def main(argv):
    if len(argv) >= 2 and argv[0] == "get":
        try:
            saved = {e.get("name"): e.get("status") != "stopped" for e in read_dump() if isinstance(e, dict)}
        except (OSError, ValueError) as e:
            out({"ok": False, "error": f"the pm2 saved list cannot be read: {e}"}, 1)
        out({"ok": True, "agent": agent_installed(), "services": {n: saved.get(n, False) for n in argv[1:]}})
    if len(argv) == 3 and argv[0] == "set" and argv[2] in ("on", "off"):
        name, on = argv[1], argv[2] == "on"
        try:
            data = read_dump()
        except (OSError, ValueError) as e:
            out({"ok": False, "error": f"the pm2 saved list cannot be read, so it was left alone: {e}"}, 1)
        hit = [e for e in data if isinstance(e, dict) and e.get("name") == name]
        if not hit:
            if not on:
                out({"ok": True})   # not saved, so it already stays off
            entry = live_entry(name)
            if entry is None:
                out({"ok": False, "error": f"pm2 does not know {name}; start it once first"}, 1)
            data.append(entry)
            hit = [entry]
        for e in hit:
            e["status"] = "online" if on else "stopped"
            e["autostart"] = True
        try:
            write_dump(data)
        except OSError as e:
            out({"ok": False, "error": f"the pm2 saved list could not be written: {e}"}, 1)
        out({"ok": True})
    out({"ok": False, "error": "usage: pm2login.py get <name>... | set <name> on|off"}, 2)


if __name__ == "__main__":
    main(sys.argv[1:])
