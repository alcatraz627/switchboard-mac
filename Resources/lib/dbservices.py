#!/usr/bin/env python3
"""Local services Homebrew runs for you (mongod, redis, postgres, nginx…):
whether each is up, the ports it listens on, where it keeps data and logs, and
a connection string to copy. Start, stop and restart go through launchd.

They are the homebrew.mxcl.* agents in ~/Library/LaunchAgents. `brew services`
is not used: it misses services from third-party taps (mongodb/brew) and is slow.

  dbservices.py list             JSON {"services": [...]}
  dbservices.py start <label>    load it (it starts itself) or kick it; JSON {ok}
  dbservices.py stop <label>     unload it, since launchd restarts a killed one; JSON {ok}
  dbservices.py restart <label>  launchctl kickstart -k; JSON {ok}
"""
import glob
import json
import os
import plistlib
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jobs import AGENTS, UID, launchctl, launchctl_list  # noqa: E402

PREFIX = "homebrew.mxcl."
SCHEMES = [("mongo", "mongodb"), ("redis", "redis"), ("postgres", "postgresql"), ("mysql", "mysql")]


def listening_ports(pid):
    try:
        r = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return sorted({int(m) for m in re.findall(r":(\d+) \(LISTEN\)", r.stdout)})


def config_value(path, pattern):
    try:
        with open(path) as f:
            m = re.search(pattern, f.read(), re.M)
        return m.group(1).strip().strip('"') if m else None
    except OSError:
        return None


def data_dir(name, args):
    """Where the service keeps its data, read from its own arguments or config."""
    if "-D" in args and args.index("-D") + 1 < len(args):
        return args[args.index("-D") + 1]
    conf = next((a.split("=", 1)[1] for a in args if a.startswith("--config=")), None)
    if conf is None and "--config" in args and args.index("--config") + 1 < len(args):
        conf = args[args.index("--config") + 1]
    conf = conf or next((a for a in args[1:] if a.endswith(".conf")), None)
    if conf:
        return config_value(conf, r"^\s*dbPath:\s*(.+)$") or config_value(conf, r"^\s*dir\s+(.+)$")
    return None


def services():
    loaded = launchctl_list()
    out = []
    for path in sorted(glob.glob(os.path.join(AGENTS, PREFIX + "*.plist"))):
        try:
            with open(path, "rb") as f:
                p = plistlib.load(f)
        except Exception:
            continue
        label = p.get("Label") or os.path.basename(path)[:-6]
        name = label[len(PREFIX):]
        args = p.get("ProgramArguments") or ([p["Program"]] if "Program" in p else [])
        pid, status = loaded.get(label, (None, None))
        ports = listening_ports(pid) if pid else []
        scheme = next((s for key, s in SCHEMES if key in name), None)
        out.append({
            "label": label, "name": name, "plist": path,
            "loaded": label in loaded, "running": pid is not None, "pid": pid, "last_exit": status,
            "ports": ports,
            "log": p.get("StandardErrorPath") or p.get("StandardOutPath"),
            "data": data_dir(name, args),
            "connect": f"{scheme}://127.0.0.1:{ports[0]}" if scheme and ports else None,
            "keep_alive": bool(p.get("KeepAlive")),
        })
    return out


def find(label):
    return next((s for s in services() if s["label"] == label), None)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for(check, seconds=15):
    """Poll until check() is true. launchd answers before the service has
    actually started or exited, so an "ok" is only said once it is so."""
    import time
    end = time.time() + seconds
    while time.time() < end:
        if check():
            return True
        time.sleep(0.3)
    return check()


def running_pid(label):
    pid, _ = launchctl_list().get(label, (None, None))
    return pid if pid and alive(pid) else None


def start(label):
    s = find(label)
    if s is None:
        return False, "no such service"
    if running_pid(label):
        return True, None
    ok, err = (launchctl("bootstrap", f"gui/{UID}", s["plist"]) if label not in launchctl_list()
               else launchctl("kickstart", f"gui/{UID}/{label}"))
    if not ok:
        return False, err
    return (True, None) if wait_for(lambda: running_pid(label) is not None) else (False, "it did not start within 15 s; see its log")


def stop(label):
    s = find(label)
    if s is None:
        return False, "no such service"
    if not s["loaded"]:
        return True, None
    pid = s["pid"]
    ok, err = launchctl("bootout", f"gui/{UID}/{label}")
    if not ok:
        return False, err
    if pid and not wait_for(lambda: not alive(pid)):
        return False, f"launchd let go of it, but pid {pid} is still running after 15 s"
    return True, None


def restart(label):
    s = find(label)
    if s is None:
        return False, "no such service"
    if not s["loaded"]:
        return start(label)
    old = s["pid"]
    ok, err = launchctl("kickstart", "-k", f"gui/{UID}/{label}")
    if not ok:
        return False, err
    started = wait_for(lambda: (running_pid(label) or old) != old)
    return (True, None) if started else (False, "it did not come back within 15 s; see its log")


def main():
    args = sys.argv[1:]
    if args[:1] == ["list"]:
        try:
            print(json.dumps({"services": services()}))
        except RuntimeError as e:
            sys.stderr.write(f"{e}\n")
            sys.exit(2)
        return
    verbs = {"start": start, "stop": stop, "restart": restart}
    if len(args) == 2 and args[0] in verbs:
        if not args[1].startswith(PREFIX):
            print(json.dumps({"ok": False, "error": "only homebrew.mxcl.* services"}))
            sys.exit(1)
        ok, err = verbs[args[0]](args[1])
        print(json.dumps({"ok": ok, "error": None if ok else err}))
        sys.exit(0 if ok else 1)
    sys.stderr.write(__doc__)
    sys.exit(64)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A crash answers in the helper's own shape, never a traceback.
        print(json.dumps({"ok": False, "error": f"Something went wrong with the database services: {e}"}))
        sys.exit(1)
