#!/usr/bin/env python3
"""The local models on this Mac (the lm suite in ~/Code/local-models): which
Ollama models are loaded and for how long, memory pressure, running mlx jobs,
and whether mem-guard (the watchdog that stops a model before macOS starts
killing other apps) is on.

The Switchboard's Machine tab calls this. Warm and mem-guard go through the
suite's own tools so the panel and `lm` never disagree.

  models.py list              JSON state
  models.py unload <model>    drop one model from memory now; JSON {ok}
  models.py unload-all        drop every loaded model (warm off all); JSON {ok}
  models.py keep <model> <t>  keep a model loaded for t (15m, 1h, 4h, forever) (warm on); JSON {ok}
  models.py warm on|off|restart  load, drop or reload the warm companion (bin/warm); JSON {ok}
  models.py guard on|off      start mem-guard, or ask it to stop; JSON {ok}

The server's own eviction defaults (how long an idle model stays, how many
can be loaded at once) are set in bin/lm-serve; `list` reports them read-only.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from http.client import HTTPException

SUITE = os.path.expanduser("~/Code/local-models")
OLLAMA = "http://127.0.0.1:11434"
GUARD_PID, GUARD_STOP = "/tmp/mem-guard.pid", "/tmp/mem-guard.stop"
PRESSURE = {1: "normal", 2: "warn", 4: "critical"}


def http(path, body=None, timeout=5):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except (ValueError, HTTPException) as e:
        # Callers treat OSError as "Ollama did not answer"; a garbled reply is the same to them.
        raise OSError(f"Ollama sent a reply that could not be read: {e}")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def guard_running():
    try:
        return pid_alive(int(open(GUARD_PID).read().strip()))
    except (OSError, ValueError):
        return False


def mlx_jobs():
    out = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True).stdout
    jobs = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and ("mlx_vlm" in parts[2] or "mlx_lm" in parts[2] or "mflux" in parts[2]):
            jobs.append({"pid": int(parts[0]), "gb": round(int(parts[1]) / 1048576, 1),
                         "what": os.path.basename(parts[2].split()[0]) + " " + " ".join(parts[2].split()[1:3])})
    return jobs


def state():
    up, resident = True, []
    try:
        for m in http("/api/ps").get("models", []):
            resident.append({"name": m.get("name"), "gb": round(m.get("size", 0) / 1e9, 1),
                             "until": m.get("expires_at")})
    except OSError:
        up = False
    try:
        level = int(subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                                   capture_output=True, text=True).stdout.strip())
    except ValueError:
        level = 0
    warm_model = None
    try:
        warm_model = json.loads(subprocess.run([os.path.join(SUITE, "bin", "lm"), "status", "--json"],
                                               capture_output=True, text=True, timeout=10).stdout).get("default_model")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return {
        "suite": os.path.isdir(SUITE),
        "ollama": up,
        "resident": resident,
        "warm_model": warm_model,
        "warm": any((r["name"] or "").split(":")[0] == warm_model for r in resident) if warm_model else False,
        "pressure": PRESSURE.get(level, "unknown"),
        "guard": guard_running(),
        "mlx": mlx_jobs(),
        "policy": server_policy(),
    }


def server_policy():
    """The eviction settings lm-serve starts Ollama with, read from the script itself."""
    out = {}
    try:
        for line in open(os.path.join(SUITE, "bin", "lm-serve")):
            line = line.strip()
            for key, name in (("OLLAMA_KEEP_ALIVE", "keep_alive"), ("OLLAMA_MAX_LOADED_MODELS", "max_loaded")):
                if line.startswith(f"export {key}="):
                    out[name] = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return out


def run_warm(args, timeout=120, then=None):
    """Runs the suite's warm tool, so the panel and `warm` never disagree.
    `then` re-checks the outcome, since warm reports success when Ollama refused."""
    try:
        r = subprocess.run([os.path.join(SUITE, "bin", "warm")] + args, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        answer(False, f"the warm tool is missing: {os.path.join(SUITE, 'bin', 'warm')}")
    except subprocess.TimeoutExpired:
        answer(False, f"warm did not finish within {timeout // 60} minutes")
    if r.returncode != 0:
        answer(False, (r.stderr or r.stdout).strip())
    if then is not None:
        err = then()
        answer(err is None, err)
    answer(True)


def resident_names():
    try:
        return [m.get("name") or "" for m in http("/api/ps").get("models", [])]
    except OSError:
        return []


def answer(ok, err=None):
    print(json.dumps({"ok": ok, "error": None if ok else (err or "failed")}))
    sys.exit(0 if ok else 1)


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    if cmd == "list":
        print(json.dumps(state()))
    elif cmd == "unload" and len(a) == 2:
        try:
            http("/api/generate", {"model": a[1], "keep_alive": 0}, timeout=15)
            answer(True)
        except OSError as e:
            answer(False, f"Ollama did not answer: {e}")
    elif cmd == "warm" and len(a) == 2 and a[1] in ("on", "off", "restart"):
        run_warm([a[1]])
    elif cmd == "unload-all" and len(a) == 1:
        run_warm(["off", "all"])
    elif cmd == "keep" and len(a) == 3 and a[2] in ("15m", "1h", "4h", "forever"):
        want = a[1]
        run_warm(["on", want, a[2]], then=lambda: None if any(n == want or n.split(":")[0] == want.split(":")[0]
                                                               for n in resident_names())
                 else f"{want} is not loaded; Ollama may not have it (ollama list)")
    elif cmd == "guard" and len(a) == 2 and a[1] in ("on", "off"):
        if a[1] == "off":
            if not guard_running():
                answer(True)
            open(GUARD_STOP, "w").close()
            # It checks the stop file every few seconds; answer once it has gone.
            for _ in range(50):
                if not guard_running():
                    answer(True)
                time.sleep(0.2)
            answer(False, "mem-guard is still running 10 s after being asked to stop")
        if guard_running():
            answer(True)
        try:
            os.remove(GUARD_STOP)
        except OSError:
            pass
        py = os.path.join(SUITE, ".venv", "bin", "python")
        try:
            subprocess.Popen([py if os.path.exists(py) else "python3", os.path.join(SUITE, "scripts", "mem-guard.py")],
                             cwd=SUITE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            answer(False, f"mem-guard could not be started: {e.strerror or e}")
        # It writes its pid file once it is up; wait briefly so the answer is honest.
        for _ in range(20):
            if guard_running():
                answer(True)
            time.sleep(0.15)
        answer(False, "mem-guard did not start (see ~/Code/local-models/logs/mem-guard.jsonl)")
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A crash answers in the helper's own shape, never a traceback.
        print(json.dumps({"ok": False, "error": f"Something went wrong with the local models: {e}"}))
        sys.exit(1)
