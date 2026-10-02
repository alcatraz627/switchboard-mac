"""Checks hooks/permission-ask.py in a scratch folder: off by default, an
Approve or Deny file answers the prompt, silence leaves it to the terminal,
and every request file is cleaned up afterwards."""
import glob
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "hooks", "permission-ask.py")
root = tempfile.mkdtemp()
env = dict(os.environ, SWITCHBOARD_ASK_ROOT=root)
ask = os.path.join(root, ".permission-ask")
req = json.dumps({"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "rm -rf build"},
                  "cwd": "/tmp/app", "permission_mode": "default"})
fails = []


def check(name, ok, got=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok or not got else f" (got: {got})"))
    if not ok:
        fails.append(name)


def run(answer=None, after=0.6, stdin=req):
    """Runs the hook; `answer` is the file suffix to drop next to the request once it appears."""
    def answer_it():
        until = time.time() + 5
        while time.time() < until:
            hits = glob.glob(os.path.join(ask, "*.json"))
            if hits:
                time.sleep(after)
                if answer == "takedown":
                    os.remove(hits[0])
                else:
                    open(hits[0][:-5] + "." + answer, "w").close()
                return
            time.sleep(0.05)
    if answer:
        threading.Thread(target=answer_it, daemon=True).start()
    t0 = time.time()
    r = subprocess.run([sys.executable, HOOK], input=stdin, capture_output=True, text=True, env=env, timeout=30)
    return r.stdout.strip(), time.time() - t0


out, took = run()
check("switched off, it says nothing and returns at once", out == "" and took < 2, f"{out!r} {took:.1f}s")

with open(os.path.join(root, ".switchboard-answers-prompts"), "w") as f:
    f.write("5")
seen = {}
def peek():
    until = time.time() + 5
    while time.time() < until:
        hits = glob.glob(os.path.join(ask, "*.json"))
        if hits:
            seen.update(json.load(open(hits[0])))
            return
        time.sleep(0.05)
threading.Thread(target=peek, daemon=True).start()
out, _ = run("approved")
check("the request names the tool and the command", seen.get("tool") == "Bash" and seen.get("what") == "rm -rf build", str(seen))
check("Approve answers allow", json.loads(out or "{}").get("hookSpecificOutput", {}).get("decision", {}).get("behavior") == "allow", out)
check("and its files are gone afterwards", not os.listdir(ask), str(os.listdir(ask)))

out, _ = run("denied")
d = json.loads(out or "{}").get("hookSpecificOutput", {}).get("decision", {})
check("Deny answers deny with a reason for Claude", d.get("behavior") == "deny" and "Switchboard" in d.get("message", ""), out)

out, took = run()
check("nobody answering leaves it to the terminal after the wait", out == "" and 4.5 < took < 8 and not os.listdir(ask), f"{out!r} {took:.1f}s")

out, took = run("takedown")
check("a request taken down without an answer goes back to the terminal at once", out == "" and took < 3, f"{out!r} {took:.1f}s")

out, took = run(stdin=json.dumps({"session_id": "s1", "tool_name": "Bash", "permission_mode": "bypassPermissions"}))
check("a session that never asks is left alone", out == "" and took < 2 and not os.listdir(ask))

print("all passed" if not fails else "some failed")
sys.exit(1 if fails else 0)
