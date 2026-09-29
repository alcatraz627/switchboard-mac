#!/usr/bin/env python3
"""The git repositories under ~/Code that need attention: uncommitted changes,
commits not pushed, a detached head, stashes, or worktrees that can be pruned.

The Switchboard's Machine tab calls this. It only reads, except `fetch` and
`prune`; it never commits, pushes or resets.

  gitscan.py list [--fresh]     JSON {repos, clean, scanned_at}; answers from the last scan at once and rescans in the background when it is over 2 min old
  gitscan.py fetch <repo>       git fetch; JSON {ok}
  gitscan.py prune <repo>       git worktree prune; JSON {ok}
"""
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from state import state_path  # noqa: E402

ROOT = os.path.expanduser("~/Code")
DEPTH = 3
SKIP = {"node_modules", ".venv", "venv", "dist", "build", "target", "__pycache__"}
CACHE = state_path("git-scan.json", ".git-scan.json")
LOCK = CACHE + ".rescan"
TTL_S = 120


def git(repo, *args, timeout=10):
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 1, "", f"git {args[0]} timed out"


def find_repos():
    repos = []

    def walk(d, depth):
        try:
            entries = list(os.scandir(d))
        except OSError:
            return
        if any(e.name == ".git" for e in entries):
            repos.append(d)
            return
        if depth == DEPTH:
            return
        for e in entries:
            if e.is_dir(follow_symlinks=False) and not e.name.startswith(".") and e.name not in SKIP:
                walk(e.path, depth + 1)

    walk(ROOT, 0)
    return repos


def inspect(repo):
    code, out, err = git(repo, "status", "--porcelain=v2", "--branch")
    if code != 0:
        return {"path": repo, "error": (err.strip() or "git status failed")[:200]}
    branch, ahead, behind, upstream, dirty = None, 0, 0, None, 0
    for line in out.splitlines():
        if line.startswith("# branch.head "):
            branch = line.split(" ", 2)[2]
        elif line.startswith("# branch.upstream "):
            upstream = line.split(" ", 2)[2]
        elif line.startswith("# branch.ab "):
            a, b = line.split()[2:4]
            ahead, behind = int(a), -int(b)
        elif not line.startswith("#"):
            dirty += 1
    # A worktree checkout shares its repo's stashes and worktree list, so only
    # the main checkout reports them; otherwise every worktree repeats them.
    is_worktree = os.path.isfile(os.path.join(repo, ".git"))
    stashes = worktrees = prunable = 0
    if not is_worktree:
        _, stash, _ = git(repo, "stash", "list")
        _, wt, _ = git(repo, "worktree", "list", "--porcelain")
        stashes = len(stash.splitlines())
        worktrees = max(0, wt.count("\nworktree ") + (1 if wt.startswith("worktree ") else 0) - 1)
        prunable = wt.count("\nprunable")
    # Ahead of some other branch (a feature branch tracking main) is not
    # "unpushed"; only count it when the branch tracks its own name.
    tracks_self = bool(upstream and branch and upstream.split("/", 1)[-1] == branch)
    return {
        "path": repo,
        "name": os.path.relpath(repo, ROOT),
        "branch": None if branch == "(detached)" else branch,
        "detached": branch == "(detached)",
        "upstream": upstream,
        "worktree": is_worktree,
        "ahead": ahead if tracks_self else 0,
        "behind": behind if tracks_self else 0,
        "dirty": dirty,
        "stashes": stashes,
        "worktrees": worktrees,
        "prunable": prunable,
    }


def needs_attention(r):
    return bool(r.get("error") or r["dirty"] or r["ahead"] or r["detached"] or r["prunable"])


def scan():
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(inspect, find_repos()))
    flagged = [r for r in results if needs_attention(r)]
    # Most urgent first: unpushed work, then uncommitted, then the rest.
    flagged.sort(key=lambda r: (not r.get("ahead"), not r.get("dirty"), r["path"]))
    data = {"repos": flagged, "clean": len(results) - len(flagged), "scanned_at": time.time()}
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, CACHE)
    try:
        os.remove(LOCK)
    except OSError:
        pass
    return data


def cached():
    """The last scan at once, however old; a stale one also starts a rescan in
    the background, so the panel never waits on ~10 s of git."""
    try:
        with open(CACHE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if time.time() - data.get("scanned_at", 0) >= TTL_S and not rescan_running():
        with open(LOCK, "w") as f:
            f.write(str(time.time()))
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "list", "--fresh"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return data


def rescan_running():
    # A rescan marks itself for up to a minute, so parallel callers start only one.
    try:
        return time.time() - float(open(LOCK).read()) < 60
    except (OSError, ValueError):
        return False


def answer(code, err):
    print(json.dumps({"ok": code == 0, "error": None if code == 0 else (err.strip() or "git failed")[:300]}))
    sys.exit(0 if code == 0 else 1)


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    if cmd == "list":
        print(json.dumps(("--fresh" not in a and cached()) or scan()))
    elif cmd in ("fetch", "prune") and len(a) == 2:
        repo = os.path.realpath(a[1])
        # Only repos under the scan root: the panel never touches anything else.
        if not repo.startswith(os.path.realpath(ROOT) + os.sep) or not os.path.exists(os.path.join(repo, ".git")):
            answer(1, "not a repository under ~/Code")
        code, _, err = git(repo, *(["fetch", "--quiet"] if cmd == "fetch" else ["worktree", "prune"]), timeout=60)
        if code == 0:
            try:
                os.remove(CACHE)   # the next list shows the new state
            except OSError:
                pass
        answer(code, err)
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    main()
