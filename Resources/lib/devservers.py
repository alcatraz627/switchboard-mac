#!/usr/bin/env python3
"""The dev servers on this Mac, as the port ledger (ports.sh) records them:
which ports are claimed or pinned, which are actually listening, and which
pm2 process runs each one.

The Switchboard's Machine tab calls this. Writes go through the same tools an
agent uses (pm2, ports.sh reap), so the ledger never disagrees with the panel.

  devservers.py list          JSON {"servers": [...], "ledger": bool}
  devservers.py start <name>  pm2 start <name>; JSON {ok}
  devservers.py stop <name>   pm2 stop <name>; JSON {ok}
  devservers.py reap          ports.sh reap --yes (expired one-offs); JSON {ok}
  devservers.py kill <port>   stop the process listening on a port; JSON {ok}
"""
import json
import os
import shlex
import signal
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jobs as launchd  # noqa: E402

PORTS = os.path.expanduser("~/.claude/scripts/dev-servers/ports.sh")


def run(argv, timeout=10):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


def pm2(*args):
    # pm2 lives on the login shell's PATH (Homebrew or nvm), not launchd's.
    return run(["/bin/zsh", "-lc", "pm2 " + " ".join(shlex.quote(x) for x in args) + " 2>&1"], timeout=15)


def listeners():
    """port -> pid of the process listening on it. Raises when lsof cannot
    answer, so a failed read never looks like every port being free."""
    code, out, err = run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
    if code != 0 and not out.strip():
        raise RuntimeError(f"lsof could not list listening ports: {err.strip() or code}")
    ports, pid = {}, None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and ":" in line:
            tail = line.rsplit(":", 1)[1]
            if tail.isdigit() and pid:
                ports.setdefault(int(tail), pid)
    return ports


def launchd_owner(pid, parents, by_pid):
    """The launchd job that started this process or one of its parents.

    A GUI app's own job (application.com.mitchellh.ghostty…) is not an owner:
    a server started in that terminal is a one-off, so it is killed, not disabled."""
    seen = 0
    while pid and pid > 1 and seen < 12:
        if pid in by_pid:
            label = by_pid[pid]
            return None if label.startswith("application.") else label
        pid, seen = parents.get(pid), seen + 1
    return None


def process_tree():
    _, out, _ = run(["ps", "-axo", "pid=,ppid="])
    parents = {}
    for line in out.split("\n"):
        parts = line.split()
        if len(parts) == 2:
            parents[int(parts[0])] = int(parts[1])
    return parents


PM2_ERROR = None   # why the last pm2 read failed, reported beside the list


def pm2_status():
    global PM2_ERROR
    code, out, _ = pm2("jlist")
    # jlist can print a banner line before the JSON when pm2's daemon was cold.
    start = out.find("[")
    try:
        if code == 0 and start >= 0:
            PM2_ERROR = None
            return {p["name"]: p.get("pm2_env", {}).get("status") for p in json.loads(out[start:])}
    except (ValueError, KeyError, TypeError):
        pass
    PM2_ERROR = "pm2 did not answer" if code != 0 else "pm2 gave a list that could not be read"
    return {}


def servers():
    """Every claim and pin in the ledger, with whether its port is listening."""
    code, out, err = run(["bash", PORTS, "list"])
    if code != 0:
        raise RuntimeError(f"The port ledger could not be read: {err.strip() or 'ports.sh exited with ' + str(code)}")
    live = listeners()
    procs = pm2_status()
    parents = process_tree()
    by_pid = {pid: label for label, (pid, _) in launchd.launchctl_list().items() if pid}
    result = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        port, tier, _state, rest = int(parts[0]), parts[1], parts[2], parts[3]
        note = parts[4] if len(parts) > 4 else ""
        # A one-off's name column carries "expires:MM-DD HH:MMZ [EXPIRED]".
        name = rest.split(" expires:")[0]
        result.append({
            "port": port,
            "tier": int(tier[1:]) if tier[1:].isdigit() else 0,
            "name": name,
            "note": note,
            "expired": rest.endswith("EXPIRED"),
            "expires": rest.split(" expires:")[1].replace(" EXPIRED", "") if " expires:" in rest else None,
            "live": port in live,
            "pid": live.get(port),
            "launchd": launchd_owner(live[port], parents, by_pid) if port in live else None,
            "pm2": procs.get(name),
        })
    return result


def answer(code, err):
    print(json.dumps({"ok": code == 0, "error": None if code == 0 else (err.strip() or "failed")}))
    sys.exit(0 if code == 0 else 1)


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    if cmd == "list":
        try:
            found = servers() if os.path.exists(PORTS) else []
        except RuntimeError as e:
            print(str(e), file=sys.stderr)
            sys.exit(2)
        print(json.dumps({"servers": found, "ledger": os.path.exists(PORTS), "pm2_error": PM2_ERROR}))
    elif cmd in ("start", "stop") and len(a) == 2:
        if a[1] not in pm2_status():
            answer(1, PM2_ERROR or f"pm2 has no process named {a[1]}")
        code, out, err = pm2(cmd, a[1])
        answer(code, err or out)
    elif cmd == "kill" and len(a) == 2 and a[1].isdigit():
        try:
            pid = listeners().get(int(a[1]))
            owners = {p: l for l, (p, _) in launchd.launchctl_list().items() if p} if pid else {}
        except RuntimeError as e:
            answer(1, str(e))
        if not pid:
            answer(1, f"nothing is listening on :{a[1]}")
        owner = launchd_owner(pid, process_tree(), owners)
        if owner:
            answer(1, f"launchd runs it as {owner} and would start it again; disable that job instead")
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as e:
            answer(1, str(e))
        answer(0, "")
    elif cmd == "reap":
        code, out, err = run(["bash", PORTS, "reap", "--yes"], timeout=30)
        answer(code, err or out)
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A crash answers in the helper's own shape, never a traceback.
        print(json.dumps({"ok": False, "error": f"Something went wrong with the dev servers: {e}"}))
        sys.exit(1)
