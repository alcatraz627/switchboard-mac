#!/usr/bin/env python3
"""Claude's settings.json with one key changed, and everything else exactly as it was.

Switchboard flips a setting (a plugin, a flag) by asking this for the new file text, so the
owner's key order and layout survive and a one-value change is a one-line diff.

Usage: settings_set.py <settings.json> <key> <value as JSON>. Prints the new file text.
"""
import json
import sys


def merged(old, new):
    # Keys already there keep their place; new ones go at the end; dropped ones go.
    if isinstance(old, dict) and isinstance(new, dict):
        out = {k: merged(old[k], new[k]) for k in old if k in new}
        out.update((k, v) for k, v in new.items() if k not in old)
        return out
    return new


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: settings_set.py <settings.json> <key> <value as JSON>")
    path, key, value = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
    with open(path, encoding="utf-8") as f:
        settings = json.load(f)
    if not isinstance(settings, dict):
        sys.exit("settings.json is not a JSON object")
    settings[key] = merged(settings.get(key), value)
    sys.stdout.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
