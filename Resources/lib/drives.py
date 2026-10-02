#!/usr/bin/env python3
"""The drives attached to this Mac beyond its own disk: external disks, SD
cards and mounted disk images, with format, size and free space.

The Switchboard's Machine tab calls this. The only write is eject; formatting
and erasing are left to Disk Utility on purpose.

  drives.py list              JSON list of mounted external volumes
  drives.py eject <disk>      eject a whole disk (all its volumes); JSON {ok}
"""
import json
import os
import plistlib
import subprocess
import sys


def info(target):
    try:
        r = subprocess.run(["diskutil", "info", "-plist", target], capture_output=True, timeout=10)
        return plistlib.loads(r.stdout) if r.returncode == 0 else {}
    except Exception:
        # A volume that hangs diskutil is skipped, not allowed to sink the list.
        return {}


def volumes():
    out = []
    try:
        names = sorted(os.listdir("/Volumes"))
    except OSError as e:
        raise RuntimeError(f"The mounted volumes could not be listed: {e.strerror or e}")
    for name in names:
        path = os.path.join("/Volumes", name)
        # The boot volume shows up here as a symlink to /.
        if os.path.islink(path) or not os.path.ismount(path):
            continue
        d = info(path)
        if not d or (d.get("Internal") and d.get("VirtualOrPhysical") != "Virtual"):
            continue
        total = d.get("TotalSize") or d.get("VolumeSize") or 0
        free = d.get("APFSContainerFree") or d.get("FreeSpace") or d.get("VolumeAvailableSpace") or 0
        out.append({
            "name": d.get("VolumeName") or name,
            "mount": path,
            "disk": d.get("ParentWholeDisk") or d.get("DeviceIdentifier"),
            "format": d.get("FilesystemName") or d.get("FilesystemType") or "unknown",
            "total_gb": round(total / 1e9, 1),
            "free_gb": round(free / 1e9, 1),
            "image": d.get("VirtualOrPhysical") == "Virtual" or "image" in (d.get("DeviceLocation") or "").lower()
                     or d.get("BusProtocol") == "Disk Image",
            "ejectable": bool(d.get("Ejectable", True)),
            "writable": bool(d.get("WritableVolume", True)),
            "protocol": d.get("BusProtocol"),
        })
    return out


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    if cmd == "list":
        try:
            print(json.dumps(volumes()))
        except RuntimeError as e:
            print(str(e), file=sys.stderr)
            sys.exit(2)
    elif cmd == "eject" and len(a) == 2:
        disk = a[1]
        # Only a whole external disk the list itself reports, never the boot disk.
        if disk not in {v["disk"] for v in volumes()}:
            print(json.dumps({"ok": False, "error": f"{disk} is not one of the attached drives"}))
            sys.exit(1)
        try:
            r = subprocess.run(["diskutil", "eject", disk], capture_output=True, text=True, timeout=60)
            ok, why = r.returncode == 0, (r.stderr or r.stdout).strip() or "eject failed"
        except subprocess.TimeoutExpired:
            ok, why = False, "diskutil did not finish within 60 s"
        # Whatever diskutil said, the list says whether the drive is still there.
        try:
            attached = disk in {v["disk"] for v in volumes()}
        except Exception:
            attached = None
        if not ok and attached is False:
            ok = True   # it went, even though diskutil complained or ran long
        elif not ok:
            why += "; it is still attached" if attached else "; whether it ejected is unknown"
        print(json.dumps({"ok": ok, "error": None if ok else why}))
        sys.exit(0 if ok else 1)
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # A crash answers in the helper's own shape, never a traceback.
        print(json.dumps({"ok": False, "error": f"Something went wrong with the drives: {e}"}))
        sys.exit(1)
