#!/usr/bin/env python3
"""The owner's scheduled jobs (launchd agents under ~/Library/LaunchAgents):
what each one is, when it runs, how its last run ended, and where it logs.

The Switchboard's Machine tab calls this. Only the owner's own agents are
listed (com.alcatraz.*, dev.*, and anything else in ~/Library/LaunchAgents),
never Apple's or third-party installers'.

  jobs.py list            JSON list of jobs
  jobs.py run <label>     start a job now (launchctl kickstart); JSON {ok}
  jobs.py start <label>   load it if unloaded, then start it; JSON {ok}
  jobs.py stop <label>    stop it; an always-running job is unloaded, since
                          launchd would restart a merely killed one; JSON {ok}
  jobs.py disable <label> stop it and keep it off across logins; JSON {ok}
  jobs.py enable <label>  undo disable and load it again; JSON {ok}
"""
import glob
import json
import os
import plistlib
import subprocess
import sys

AGENTS = os.path.expanduser("~/Library/LaunchAgents")
UID = os.getuid()
# Prefixes of installers that are not the owner's own work.
FOREIGN = ("com.google.", "com.microsoft.", "com.adobe.", "com.apple.", "us.zoom.", "com.docker.",
           "com.dropbox.", "com.valvesoftware.", "com.spotify.", "homebrew.mxcl.", "com.openssh.")


def launchctl_list():
    """label -> (pid or None, last exit status) for every loaded job.

    Raises when launchctl cannot answer, so the panel says the list could not
    be read instead of showing every job as not loaded."""
    try:
        r = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"launchctl list did not answer: {e}")
    if r.returncode != 0:
        raise RuntimeError(f"launchctl list failed: {r.stderr.strip() or r.returncode}")
    out = r.stdout
    loaded = {}
    for line in out.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        pid, status, label = parts
        loaded[label] = (None if pid == "-" else int(pid), int(status) if status.lstrip("-").isdigit() else None)
    return loaded


def describe_schedule(p):
    if "StartInterval" in p:
        s = int(p["StartInterval"])
        return f"every {s // 3600}h" if s % 3600 == 0 else f"every {s // 60}m" if s % 60 == 0 else f"every {s}s"
    cal = p.get("StartCalendarInterval")
    if cal:
        cals = cal if isinstance(cal, list) else [cal]
        days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        bits = []
        for c in cals[:3]:
            t = f"{c.get('Hour', 0):02d}:{c.get('Minute', 0):02d}" if "Hour" in c else f":{c.get('Minute', 0):02d} hourly"
            when = (days[c["Weekday"] % 7] + " " if "Weekday" in c else "") + \
                   (f"day {c['Day']} " if "Day" in c else "")
            bits.append(when + t)
        more = f" +{len(cals) - 3}" if len(cals) > 3 else ""
        return ", ".join(bits) + more
    if p.get("KeepAlive"):
        return "always running"
    if p.get("RunAtLoad"):
        return "at login"
    if p.get("WatchPaths"):
        return "on file change"
    return "on demand"


def disabled_labels():
    """Labels launchctl disable has switched off (they stay off across logins)."""
    try:
        r = subprocess.run(["launchctl", "print-disabled", f"gui/{UID}"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"launchctl print-disabled did not answer: {e}")
    if r.returncode != 0:
        # Without this a failed read shows every switched-off job as enabled.
        raise RuntimeError(f"launchctl print-disabled failed: {r.stderr.strip() or r.returncode}")
    out = r.stdout
    off = set()
    for line in out.splitlines():
        line = line.strip()
        if "=>" in line and line.startswith('"'):
            label, state = line.split("=>", 1)
            if state.strip() in ("disabled", "true"):
                off.add(label.strip().strip('"'))
    return off


def describe_job(path, loaded, switched_off):
    """One of the owner's launchd jobs as the panel shows it, or None for a foreign one."""
    with open(path, "rb") as f:
        p = plistlib.load(f)
    label = p.get("Label") or os.path.basename(path)[:-6]
    if not isinstance(label, str):
        return None
    if label.startswith(FOREIGN):
        return None
    pid, status = loaded.get(label, (None, None))
    prog = p.get("Program") or (p.get("ProgramArguments") or [""])[0]
    args = p.get("ProgramArguments") or []
    # The script a wrapper runs says more than "/bin/bash" does.
    script = next((a for a in args[1:] if a.endswith((".sh", ".py", ".js", ".ts", ".mjs"))), None)
    log = p.get("StandardErrorPath") or p.get("StandardOutPath")
    return {
        "label": label,
        "name": label.split(".")[-1].replace("-", " "),
        "schedule": describe_schedule(p),
        "loaded": label in loaded,
        "running": pid is not None,
        "last_exit": status,
        "failing": status not in (None, 0) and pid is None,
        "disabled": bool(p.get("Disabled")) or label in switched_off,
        "pid": pid,
        "program": os.path.basename(script or prog or ""),
        "plist": path,
        "log": log if log and os.path.exists(os.path.expanduser(log)) else None,
    }


def jobs():
    loaded = launchctl_list()
    switched_off = disabled_labels()
    result = []
    for path in sorted(glob.glob(os.path.join(AGENTS, "*.plist"))):
        try:
            entry = describe_job(path, loaded, switched_off)
        except Exception:
            continue   # one malformed plist is skipped, never the whole list
        if entry:
            result.append(entry)
    # Two plists can share a Label tail (pm2's user and root agents are both
    # "PM2"); name those by their file so the rows can be told apart.
    names = [j["name"] for j in result]
    for j in result:
        if names.count(j["name"]) > 1:
            j["name"] = os.path.basename(j["plist"])[:-6].replace(".", " ").replace("-", " ")
    # Failing first, then running, then the rest by name.
    result.sort(key=lambda j: (not j["failing"], not j["running"], j["name"]))
    return result


def launchctl(*argv):
    try:
        r = subprocess.run(["launchctl", *argv], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"launchctl {argv[0]} did not answer: {e}"
    return r.returncode == 0, (r.stderr.strip() or r.stdout.strip() or f"launchctl exit {r.returncode}")


def find(label):
    return next((j for j in jobs() if j["label"] == label), None)


def start(label):
    j = find(label)
    if j is None:
        return False, "no such job"
    if not j["loaded"]:
        ok, err = launchctl("bootstrap", f"gui/{UID}", j["plist"])
        if not ok:
            return False, err
        # A KeepAlive or RunAtLoad job starts on load; kicking it again would restart it.
        if j["schedule"] in ("always running", "at login"):
            return True, None
    return launchctl("kickstart", f"gui/{UID}/{label}")


def stop(label):
    j = find(label)
    if j is None:
        return False, "no such job"
    if j["schedule"] == "always running":
        if not j["loaded"]:
            return True, None
        return launchctl("bootout", f"gui/{UID}/{label}")
    if not j["running"]:
        return True, None
    return launchctl("kill", "SIGTERM", f"gui/{UID}/{label}")


def disable(label):
    j = find(label)
    if j is None:
        return False, "no such job"
    ok, err = launchctl("disable", f"gui/{UID}/{label}")
    if not ok:
        return False, err
    if j["loaded"]:
        return launchctl("bootout", f"gui/{UID}/{label}")
    return True, None


def enable(label):
    j = find(label)
    if j is None:
        return False, "no such job"
    ok, err = launchctl("enable", f"gui/{UID}/{label}")
    if not ok:
        return False, err
    # Load it only: an always-on job starts by itself, and a scheduled one waits
    # for its time rather than running now.
    if not j["loaded"]:
        return launchctl("bootstrap", f"gui/{UID}", j["plist"])
    return True, None


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "help"
    if cmd == "list":
        try:
            print(json.dumps(jobs()))
        except RuntimeError as e:
            print(str(e), file=sys.stderr)
            sys.exit(2)
    elif cmd in ("run", "start", "stop", "disable", "enable") and len(args) == 2:
        if cmd == "run":
            ok, err = launchctl("kickstart", f"gui/{UID}/{args[1]}")
        else:
            ok, err = {"start": start, "stop": stop, "disable": disable, "enable": enable}[cmd](args[1])
        print(json.dumps({"ok": ok, "error": None if ok else err}))
        sys.exit(0 if ok else 1)
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A crash answers in the helper's own shape, never a traceback.
        print(json.dumps({"ok": False, "error": f"Something went wrong with the schedules: {e}"}))
        sys.exit(1)
