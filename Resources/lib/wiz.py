#!/usr/bin/env python3
"""Smart bulbs on the home network (Philips WiZ): find them, read them, set them.

The Switchboard's Home tab calls this; it can also be run by hand. It speaks
WiZ's local UDP protocol directly (port 38899, JSON messages), so there is no
cloud, no account and no credential. Names the owner gives bulbs live in
wiz-names.json in Switchboard's state folder (see state.py), keyed by MAC.

  wiz.py discover [--timeout 3]          JSON list of bulbs with their state
  wiz.py set <ip> key=value ...          keys: state=on|off, dimming=10-100,
                                         temp=2200-6500, scene=1-32,
                                         rgb=RRGGBB, speed=10-200 (animated scenes)
  wiz.py name <mac> "<name>"             save a display name ("" removes it)
  wiz.py scenes                          JSON id-to-name table

Exit 0 with JSON on stdout; exit 1 with {"error": ...} when a bulb does not answer.
"""
import json
import os
import socket
import sys
import time

from state import state_path

PORT = 38899
NAMES = state_path("wiz-names.json", ".wiz-names.json")
KNOWN = state_path("wiz-known.json")        # mac -> last address, so a missed broadcast loses nothing
REPLY_TIMEOUT = 2.0

# WiZ's built-in scene ids, as the bulbs number them.
SCENES = {
    1: "Ocean", 2: "Romance", 3: "Sunset", 4: "Party", 5: "Fireplace", 6: "Cozy",
    7: "Forest", 8: "Pastel Colors", 9: "Wake Up", 10: "Bedtime", 11: "Warm White",
    12: "Daylight", 13: "Cool White", 14: "Night Light", 15: "Focus", 16: "Relax",
    17: "True Colors", 18: "TV Time", 19: "Plant Growth", 20: "Spring", 21: "Summer",
    22: "Fall", 23: "Deep Dive", 24: "Jungle", 25: "Mojito", 26: "Club",
    27: "Christmas", 28: "Halloween", 29: "Candlelight", 30: "Golden White",
    31: "Pulse", 32: "Steampunk",
}


def out(obj, code=0):
    print(json.dumps(obj))
    sys.exit(code)


def load_names(strict=False):
    """Saved bulb names. Missing means none; an unreadable file is empty for a
    read, but refuses a write (strict), so a rename never erases the others."""
    if not os.path.exists(NAMES):
        return {}
    try:
        with open(NAMES) as f:
            d = json.load(f)
        if isinstance(d, dict):
            return d
    except Exception:
        pass
    if strict:
        print(json.dumps({"error": f"the bulb names file is unreadable, so it was left alone: {NAMES}"}))
        sys.exit(1)
    return {}


def local_ip():
    # The address the machine would use to reach the internet: the LAN one.
    # No packet is sent; connect() on UDP only picks a route. With no route
    # (Wi-Fi off, no network) the bulbs only use it to reply, so any will do.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "0.0.0.0"
    finally:
        s.close()


def ask(ip, method, params=None, timeout=REPLY_TIMEOUT):
    """One request to one bulb; its result dict, or None if it did not answer."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(json.dumps({"method": method, "params": params or {}}).encode(), (ip, PORT))
        data, _ = s.recvfrom(4096)
        msg = json.loads(data)
        return msg.get("result") if isinstance(msg, dict) else None
    except (socket.timeout, OSError, ValueError):
        return None
    finally:
        s.close()


def ask_retry(ip, method, params=None, tries=4):
    """A bulb that has just applied a change can miss the next request, so
    reads right after a write get a few spaced attempts."""
    for i in range(tries):
        r = ask(ip, method, params, timeout=0.8)
        if r:
            return r
        time.sleep(0.15 * (i + 1))
    return None


def bulb_state(ip, mac, names):
    r = ask_retry(ip, "getPilot") or {}
    scene = r.get("sceneId")
    return {
        "ip": ip, "mac": mac, "name": names.get(mac) or "",
        "reachable": bool(r),
        "on": bool(r.get("state")),
        "dimming": r.get("dimming"),
        "temp": r.get("temp"),
        "scene": scene if scene else None,
        "scene_name": SCENES.get(scene) if scene else None,
        "rgb": [r.get("r"), r.get("g"), r.get("b")] if r.get("r") is not None else None,
        "speed": r.get("speed"),
    }


def load_known():
    try:
        with open(KNOWN) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_known(known):
    tmp = KNOWN + ".tmp"
    with open(tmp, "w") as f:
        json.dump(known, f, indent=2)
    os.replace(tmp, KNOWN)


def discover(timeout):
    """Every bulb on the network, plus every bulb seen before.

    One broadcast is easily lost (measured: 3 of 8 back-to-back scans found
    3, 2 and 0 of 5 bulbs), so the broadcast repeats through the window, and
    each bulb seen before is also asked directly at its last address. A known
    bulb that still does not answer is listed as not reachable, not dropped.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.2)
    msg = json.dumps({"method": "registration",
                      "params": {"phoneMac": "AAAAAAAAAAAA", "register": False,
                                 "phoneIp": local_ip(), "id": "1"}}).encode()
    known = load_known()
    found = {}
    end = time.time() + timeout
    next_send = 0.0
    while time.time() < end:
        if time.time() >= next_send:
            # A send fails with no network or no route to one address; the
            # others, and the next round, still go out.
            for target in [("255.255.255.255", PORT)] + [(ip, PORT) for mac, ip in known.items() if mac not in found]:
                try:
                    s.sendto(msg, target)
                except OSError:
                    pass
            next_send = time.time() + 0.6
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        # Anything on the LAN can answer on this port; a packet that is not a
        # bulb's reply is skipped, never the end of the search.
        try:
            reply = json.loads(data)
        except ValueError:
            continue
        r = reply.get("result") if isinstance(reply, dict) else None
        if isinstance(r, dict) and r.get("mac"):
            found[r["mac"]] = addr[0]
    s.close()
    if found:
        known.update(found)
        save_known(known)
    names = load_names()
    bulbs = [bulb_state(ip, mac, names) for mac, ip in found.items()]
    for mac, ip in known.items():
        if mac not in found:
            bulbs.append({"ip": ip, "mac": mac, "name": names.get(mac) or "", "reachable": False,
                          "on": False, "dimming": None, "temp": None, "scene": None,
                          "scene_name": None, "rgb": None, "speed": None})
    # Named bulbs first, then by address, so the list order is stable.
    def ip_key(ip):
        try:
            return tuple(int(x) for x in ip.split("."))
        except (ValueError, AttributeError):
            return (999,)   # a damaged saved address sorts last rather than ending the scan
    bulbs.sort(key=lambda b: (b["name"] == "", b["name"].lower(), ip_key(b["ip"])))
    return bulbs


def parse_set(pairs):
    params = {}
    for p in pairs:
        if "=" not in p:
            out({"error": f"expected key=value, got {p}"}, 2)
        k, v = p.split("=", 1)
        try:
            if k == "state":
                if v not in ("on", "off"):
                    raise ValueError
                params["state"] = v == "on"
            elif k == "dimming":
                n = int(v)
                if not 10 <= n <= 100:
                    raise ValueError
                params["dimming"] = n
            elif k == "temp":
                n = int(v)
                if not 2200 <= n <= 6500:
                    raise ValueError
                params["temp"] = n
            elif k == "scene":
                n = int(v)
                if n not in SCENES:
                    raise ValueError
                params["sceneId"] = n
            elif k == "rgb":
                h = v.lstrip("#")
                if len(h) != 6:
                    raise ValueError
                params["r"], params["g"], params["b"] = (int(h[i:i + 2], 16) for i in (0, 2, 4))
            elif k == "speed":
                n = int(v)
                if not 10 <= n <= 200:
                    raise ValueError
                params["speed"] = n
            else:
                out({"error": f"unknown key {k}"}, 2)
        except ValueError:
            out({"error": f"invalid value for {k}: {v}"}, 2)
    if not params:
        out({"error": "nothing to set"}, 2)
    return params


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "help"
    if cmd == "discover":
        t = 3.0
        if "--timeout" in args:
            t = float(args[args.index("--timeout") + 1])
        out(discover(t))
    elif cmd == "set" and len(args) >= 3:
        ip, params = args[1], parse_set(args[2:])
        r = ask(ip, "setPilot", params)
        if not r or r.get("success") is not True:
            out({"error": f"bulb {ip} did not confirm the change"}, 1)
        mac = (ask_retry(ip, "getSystemConfig") or {}).get("mac", "")
        b = bulb_state(ip, mac, load_names())
        if not b["reachable"]:
            # The bulb confirmed the change, then missed the read-back: show
            # what it confirmed rather than an off bulb.
            b.update(reachable=True, confirmed_only=True)
            if "state" in params:
                b["on"] = params["state"]
            for k in ("dimming", "temp", "speed"):
                if k in params:
                    b[k] = params[k]
            if "sceneId" in params:
                b["scene"], b["scene_name"] = params["sceneId"], SCENES.get(params["sceneId"])
            if "r" in params:
                b["rgb"] = [params["r"], params["g"], params["b"]]
            if "state" not in params:
                b["on"] = True   # every other change is made to a lit bulb
        out(b)
    elif cmd == "name" and len(args) == 3:
        names = load_names(strict=True)
        if args[2]:
            names[args[1]] = args[2]
        else:
            names.pop(args[1], None)
        tmp = NAMES + ".tmp"
        with open(tmp, "w") as f:
            json.dump(names, f, indent=2)
        os.replace(tmp, NAMES)
        out({"ok": True})
    elif cmd == "scenes":
        out({str(k): v for k, v in SCENES.items()})
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        # A save that could not be written (disk full, permissions): say so in
        # the helper's own JSON shape instead of a traceback.
        out({"error": f"could not save: {e.strerror or e}"}, 1)
    except Exception as e:
        out({"error": f"Something went wrong with the bulbs: {e}"}, 1)
