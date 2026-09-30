"""Does bulb discovery survive a noisy network, and does a confirmed change
read as done when the bulb misses the read-back?

A fake bulb answers on 127.0.0.1:38899. Before its real reply it sends what
other LAN devices do: a JSON array and a non-JSON packet. Prints one line:
  discover:<found|missing|crashed> set:<on|off after a confirmed set with no read-back>
Needs SWITCHBOARD_STATE pointing at a scratch folder.
"""
import json, os, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
WIZ = os.path.join(HERE, "..", "..", "Resources", "lib", "wiz.py")
state = os.environ["SWITCHBOARD_STATE"]
os.makedirs(state, exist_ok=True)
with open(os.path.join(state, "wiz-known.json"), "w") as f:
    json.dump({"aa00000000f1": "127.0.0.1"}, f)

mode = {"answer_reads": True}
srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 38899))
srv.settimeout(0.2)
stop = False


def serve():
    while not stop:
        try:
            data, addr = srv.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            return
        msg = json.loads(data)
        m = msg.get("method")
        if m == "registration":
            srv.sendto(b"[1, 2, 3]", addr)             # another device's array
            srv.sendto(b"not json at all", addr)        # a malformed datagram
            srv.sendto(json.dumps({"result": {"mac": "aa00000000f1", "success": True}}).encode(), addr)
        elif m == "setPilot":
            srv.sendto(json.dumps({"result": {"success": True}}).encode(), addr)
        elif mode["answer_reads"] and m == "getPilot":
            srv.sendto(json.dumps({"result": {"state": True, "dimming": 40}}).encode(), addr)
        elif mode["answer_reads"] and m == "getSystemConfig":
            srv.sendto(json.dumps({"result": {"mac": "aa00000000f1"}}).encode(), addr)


t = threading.Thread(target=serve, daemon=True)
t.start()
try:
    r = subprocess.run([sys.executable, WIZ, "discover", "--timeout", "1.5"], capture_output=True, text=True, timeout=30)
    try:
        # real bulbs on the LAN may answer the broadcast too; only the fake one counts
        found = [b["mac"] for b in json.loads(r.stdout) if b.get("reachable")]
        disc = "found" if "aa00000000f1" in found else "missing"
    except ValueError:
        disc = "crashed"
    mode["answer_reads"] = False                          # the bulb applies the change, then misses the read
    r = subprocess.run([sys.executable, WIZ, "set", "127.0.0.1", "state=on"], capture_output=True, text=True, timeout=30)
    try:
        b = json.loads(r.stdout)
        setr = "on" if b.get("on") else "off" if "on" in b else "error"
    except ValueError:
        setr = "crashed"
    print(f"discover:{disc} set:{setr}")
finally:
    stop = True
    srv.close()
