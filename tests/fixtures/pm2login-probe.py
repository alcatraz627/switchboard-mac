"""Checks pm2login.py against a scratch pm2 folder: reads follow pm2's rule
(stopped stays off, anything else starts), a switch changes only its own
entry, and a damaged saved list is reported and left as it was."""
import json
import os
import subprocess
import sys
import tempfile

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Resources", "lib", "pm2login.py")
home = tempfile.mkdtemp()
dump = os.path.join(home, "dump.pm2")
env = dict(os.environ, PM2_HOME=home, PM2LOGIN_AGENT="1")
fails = []


def run(*args):
    r = subprocess.run([sys.executable, HELPER, *args], capture_output=True, text=True, env=env)
    return r.returncode, json.loads(r.stdout or "{}")


def check(name, ok):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        fails.append(name)


saved = [{"name": "kanban", "status": "online", "pm_exec_path": "/bin/k"},
         {"name": "other", "status": "online", "pm_exec_path": "/bin/o", "extra": [1, 2]},
         {"name": "session-hub", "status": "stopped", "pm_exec_path": "/bin/h"}]
with open(dump, "w") as f:
    json.dump(saved, f)

_, g = run("get", "kanban", "session-hub", "decision-pages")
check("reads: online starts at login, stopped and unsaved do not",
      g.get("services") == {"kanban": True, "session-hub": False, "decision-pages": False} and g.get("agent") is True)

code, s = run("set", "session-hub", "on")
after = json.load(open(dump))
check("switching one on marks only its entry", code == 0 and s.get("ok") and after[2]["status"] == "online")
check("every other entry is kept exactly", after[0] == saved[0] and after[1] == saved[1])
check("the previous list is kept as a backup", json.load(open(dump + ".bak")) == saved)

run("set", "kanban", "off")
_, g = run("get", "kanban", "session-hub")
check("switching one off reads back off", g.get("services") == {"kanban": False, "session-hub": True})

code, s = run("set", "never-saved", "off")
check("switching off a service that was never saved is already done", code == 0 and s.get("ok"))

with open(dump, "w") as f:
    f.write("{not json")
code, s = run("set", "kanban", "on")
check("a damaged list is reported and left as it was",
      code == 1 and s.get("ok") is False and open(dump).read() == "{not json")

print("all passed" if not fails else "some failed")
sys.exit(1 if fails else 0)
