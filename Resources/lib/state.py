"""Where Switchboard's helpers keep what the owner saves (bulb names, wake targets).

Everything lives in one folder, ~/Library/Application Support/Switchboard, or
$SWITCHBOARD_STATE when set (tests point it at a temp dir). A file saved by an
older build under ~/.claude/widgets is copied across the first time it is asked
for, so upgrading never loses a saved device.
"""
import os
import shutil

LEGACY_DIR = os.path.expanduser("~/.claude/widgets")


def state_dir():
    d = os.environ.get("SWITCHBOARD_STATE") or os.path.expanduser(
        "~/Library/Application Support/Switchboard")
    os.makedirs(d, exist_ok=True)
    return d


def state_path(name, legacy_name=None):
    """Path to a state file, adopting the pre-extraction copy if only that exists."""
    p = os.path.join(state_dir(), name)
    if not os.path.exists(p) and not os.environ.get("SWITCHBOARD_STATE"):
        old = os.path.join(LEGACY_DIR, legacy_name or name)
        if os.path.exists(old):
            shutil.copy2(old, p)
    return p
