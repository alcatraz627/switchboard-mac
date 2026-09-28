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
"""
import json
import os
import shlex
import subprocess
import sys

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


def listening_ports():
    _, out, _ = run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fn"])
    ports = set()
    for line in out.splitlines():
        if line.startswith("n") and ":" in line:
            tail = line.rsplit(":", 1)[1]
            if tail.isdigit():
                ports.add(int(tail))
    return ports


def pm2_status():
    code, out, _ = pm2("jlist")
    # jlist can print a banner line before the JSON when pm2's daemon was cold.
    start = out.find("[")
    try:
        return {p["name"]: p.get("pm2_env", {}).get("status") for p in json.loads(out[start:])} if code == 0 and start >= 0 else {}
    except (ValueError, KeyError, TypeError):
        return {}


def servers():
    """Every claim and pin in the ledger, with whether its port is listening."""
    _, out, _ = run(["bash", PORTS, "list"])
    live = listening_ports()
    procs = pm2_status()
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
        print(json.dumps({"servers": servers() if os.path.exists(PORTS) else [], "ledger": os.path.exists(PORTS)}))
    elif cmd in ("start", "stop") and len(a) == 2:
        if a[1] not in pm2_status():
            answer(1, f"pm2 has no process named {a[1]}")
        code, out, err = pm2(cmd, a[1])
        answer(code, err or out)
    elif cmd == "reap":
        code, out, err = run(["bash", PORTS, "reap", "--yes"], timeout=30)
        answer(code, err or out)
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    main()
