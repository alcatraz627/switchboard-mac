// NotesSyncProbe.swift
// The headless checks for NotesSync: the repository side of notes in a scratch folder, then the GitHub
// side against scratch clones with a bare local repository as the remote. Nothing here touches the
// owner's notes, the app's own defaults or a real remote.

import Foundation

/// The repository side of notes, in a scratch folder: commits land, history
/// reads back, a clash is counted, and a remote that is not there is a sentence.
func probeNotesSync() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    NotesStore.remindersOff = true
    let s = NotesStore()
    let sync = NotesSync.shared
    let n = s.add("Sync me\nfirst body")!
    sync.commitNow("save")
    check("a saved note is committed", sync.history(of: n.id).count == 1, "\(sync.history(of: n.id).count)")
    var e = n; e.body = "second body"
    s.update(e)
    sync.commitNow("save")
    let h = sync.history(of: n.id)
    check("an edit is a second version, newest first", h.count == 2 && h[0].reason == "save")
    check("an old version reads back", sync.version(of: n.id, at: h[1].sha)?.contains("first body") == true)
    check("an old version parses as the note it was, ready to bring back",
          sync.version(of: n.id, at: h[1].sha).flatMap { NotesStore.parse(id: n.id, $0) }?.body == "first body")
    check("order.json is never committed", sync.git(["check-ignore", "order.json"]).code == 0)
    check(".trash is never committed", sync.git(["check-ignore", ".trash/x.md"]).code == 0)
    try? "---\ntitle: clash\n---\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> origin/main\n".write(toFile: NotesStore.dir + "/clash.md", atomically: true, encoding: .utf8)
    check("a file holding both sides counts as a clash", NotesSync.countConflicts(in: NotesStore.dir) == 1)
    s.load()
    check("the clash shows on the note", s.notes.first { $0.id == "clash" }?.conflicted == true)
    try? FileManager.default.removeItem(atPath: NotesStore.dir + "/clash.md")
    // with no remote set, the timer's sync still turns a file another tool wrote into a version
    NotesStore.defaults.removeObject(forKey: NotesSync.remoteKey)
    try? "---\ntitle: by hand\n---\nwritten by another tool\n".write(toFile: NotesStore.dir + "/byhand.md", atomically: true, encoding: .utf8)
    let alone = sync.syncNow(force: true)
    check("a file another tool wrote becomes a version on the next round, remote or not",
          sync.history(of: "byhand").count == 1, "\(sync.history(of: "byhand").count)")
    check("with no address anywhere the state says so in words and is not ok",
          !alone.ok && alone.problem?.contains("only on this Mac") == true, alone.problem ?? "nil")
    return lines + probeGitHubSync() + probeRuns()
}

// ── GitHub side: scratch clones and a bare remote ───────────────────────────

private func probeGitHubSync() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "sb-mntsync-\(getpid())"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let bare = root + "/remote.git", mac = root + "/mac", other = root + "/other", seed = root + "/seed"

    @discardableResult func g(_ cwd: String, _ a: String...) -> GitResult { NotesSync.runGit(a, cwd: cwd) }
    func put(_ base: String, _ f: String, _ t: String) {
        try? fm.createDirectory(atPath: (base + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? t.write(toFile: base + "/" + f, atomically: true, encoding: .utf8)
    }
    func read(_ base: String, _ f: String) -> String { (try? String(contentsOfFile: base + "/" + f, encoding: .utf8)) ?? "" }
    func note(_ title: String, pos: String? = nil, body: String) -> String {
        "---\ntitle: \"\(title)\"\ncreated: 2026-10-01T00:00:00Z\n" + (pos.map { "pos: \($0)\n" } ?? "") + "---\n\(body)\n"
    }
    func identify(_ d: String) { g(d, "config", "user.name", "T"); g(d, "config", "user.email", "t@t") }
    func otherSaves(_ msg: String) {
        g(other, "add", "-A"); g(other, "commit", "-q", "-m", msg); g(other, "push", "-q", "origin", "HEAD:main")
    }

    g(root, "init", "-q", "--bare", "-b", "main", bare)
    g(root, "init", "-q", "-b", "main", seed); identify(seed)
    put(seed, "notes/seed.md", note("Seed", body: "first")); put(seed, "other/keep.txt", "another namespace\n")
    g(seed, "add", "-A"); g(seed, "commit", "-q", "-m", "seed"); g(seed, "remote", "add", "origin", bare); g(seed, "push", "-q", "origin", "main")
    g(root, "clone", "-q", bare, mac); identify(mac)
    g(root, "clone", "-q", bare, other); identify(other)

    let sync = NotesSync.shared
    let defaults = NotesStore.defaults
    let oldFolder = defaults.string(forKey: NotesStore.folderKey)
    defaults.set(mac + "/notes", forKey: NotesStore.folderKey)
    defaults.removeObject(forKey: NotesSync.remoteKey)
    defer {
        if let f = oldFolder { defaults.set(f, forKey: NotesStore.folderKey) } else { defaults.removeObject(forKey: NotesStore.folderKey) }
        defaults.removeObject(forKey: NotesSync.remoteKey)
    }

    // 1. a folder inside a clone is the clone's, never a repository of its own
    check("the repository is found above the notes folder", sync.repo()?.prefix == "notes/" && sync.repo()?.top.hasSuffix("/mac") == true,
          sync.repo().map { "\($0.top) \($0.prefix)" } ?? "nil")
    check("ensureRepo does not git init inside the subfolder", sync.ensureRepo() && !fm.fileExists(atPath: mac + "/notes/.git"))

    // 2. a save commits only the notes folder
    put(mac, "notes/n1.md", note("One", pos: "i", body: "first words"))
    put(mac, "other/keep.txt", "edited by another tool\n")
    put(mac, "other/staged.txt", "staged by another tool\n"); g(mac, "add", "other/staged.txt")
    sync.commitNow("save")
    let files = g(mac, "show", "--name-only", "--format=", "HEAD").out
    check("a save commits only the notes folder", files.contains("notes/n1.md") && !files.contains("other/"), files)
    check("another folder's staged change stays staged and uncommitted", g(mac, "diff", "--cached", "--name-only").out.contains("other/staged.txt"))
    g(mac, "reset", "-q", "other/staged.txt"); try? fm.removeItem(atPath: mac + "/other/staged.txt"); g(mac, "checkout", "-q", "--", "other/keep.txt")

    // 3. ids are relative to the notes folder, versions read in the subfolder
    check("edit times are keyed by plain note ids", sync.editTime("n1") != nil && sync.editTime("seed") != nil && !sync.editTimes.keys.contains { $0.contains("/") },
          sync.editTimes.keys.sorted().joined(separator: ","))
    let hist = sync.history(of: "n1")
    check("history of a note in a subfolder lists its commit", hist.count == 1, "\(hist.count)")
    check("a version reads back from the subfolder", hist.first.flatMap { sync.version(of: "n1", at: $0.sha) }?.contains("first words") == true)

    // 4. a big note reads back
    let big = String(repeating: "0123456789abcdef", count: 16_000)   // 256 KB
    put(mac, "notes/big.md", note("Big", body: big))
    sync.commitNow("save")
    let bigHist = sync.history(of: "big")
    let bigBack = bigHist.first.flatMap { sync.version(of: "big", at: $0.sha) }
    check("a note over 64 KB reads back whole", (bigBack?.count ?? 0) > 250_000, "\(bigBack?.count ?? 0)")

    // 5. the first round: origin is already there, the save goes up, the state file is written
    let r1 = sync.syncNow(force: true)
    check("a round with the clone's own origin succeeds and pushes", r1.ok && r1.ahead == 0 && r1.behind == 0, "\(r1)")
    check("GitHub's copy is this Mac's HEAD", g(mac, "rev-parse", "HEAD").out == g(bare, "rev-parse", "main").out)
    let stateText = read(mac, ".git/mnt-sync-state.json")
    let stateJSON = (try? JSONSerialization.jsonObject(with: Data(stateText.utf8))) as? [String: Any]
    let keys = ["at", "ok", "problem", "ahead", "behind", "clashes", "cameBack", "lastOk"]
    check("the state file holds exactly the spec's keys", Set(stateJSON?.keys.map { $0 } ?? []) == Set(keys) && stateJSON?["ok"] as? Bool == true
          && stateJSON?["problem"] is NSNull && (stateJSON?["cameBack"] as? [Any])?.isEmpty == true, stateText)
    check("there is no remote named pi", !g(mac, "remote").out.contains("pi") && g(mac, "remote").out.contains("origin"))

    // 6. another device's change merges in
    g(other, "pull", "-q", "--no-rebase"); put(other, "notes/o1.md", note("From the other", body: "hello")); otherSaves("other: add")
    let r2 = sync.syncNow(force: true)
    check("a change from a second clone merges in", fm.fileExists(atPath: mac + "/notes/o1.md") && r2.ok, "\(r2)")
    check("an empty tick after that is quiet and still ok", sync.syncNow(force: false).ok)

    // 7. body clash keeps both sides, and sync does not stop
    put(mac, "notes/n1.md", note("One", pos: "i", body: "mac words"))
    g(other, "pull", "-q", "--no-rebase"); put(other, "notes/n1.md", note("One", pos: "i", body: "other words")); otherSaves("other: edit")
    let r3 = sync.syncNow(force: true)
    let n1 = read(mac, "notes/n1.md")
    check("a body clash keeps both sides with markers", n1.contains("<<<<<<<") && n1.contains("mac words") && n1.contains("other words"), n1)
    check("the round after a body clash is ok, pushed, and counts one clash", r3.ok && r3.ahead == 0 && r3.clashes == 1, "\(r3)")
    check("a file with a clash is read as the whole file, titled by its name",
          NotesStore.parse(id: "n1", n1).map { $0.title == "n1" && $0.body.contains("mac words") && $0.conflicted } == true)
    check("settling a clash writes back a note that is no longer a clash",
          NotesStore.parse(id: "n1", NotesSync.resolve(n1, keep: .both)).map { !$0.conflicted && $0.title == "One" } == true)
    put(mac, "notes/n1.md", note("One", pos: "i", body: "settled"))
    sync.syncNow(force: true)

    // 8. pos-only clash takes this Mac's side
    put(mac, "notes/p1.md", note("Moved", pos: "i", body: "same body")); sync.syncNow(force: true)
    g(other, "pull", "-q", "--no-rebase"); put(other, "notes/p1.md", note("Moved", pos: "r", body: "same body")); otherSaves("other: move")
    put(mac, "notes/p1.md", note("Moved", pos: "4", body: "same body"))
    let r4 = sync.syncNow(force: true)
    let p1 = read(mac, "notes/p1.md")
    check("a pos-only clash settles to this Mac's side with no markers", p1.contains("pos: 4") && !p1.contains("<<<<<<<") && r4.clashes == 0, p1)

    // 9. a clash across the closing fence is still a clash for the whole file
    put(mac, "notes/f1.md", note("Fence", pos: "i", body: "first line\nrest")); sync.syncNow(force: true)
    g(other, "pull", "-q", "--no-rebase"); put(other, "notes/f1.md", note("Fence", pos: "r", body: "other first\nrest")); otherSaves("other: fence")
    put(mac, "notes/f1.md", note("Fence", pos: "4", body: "mac first\nrest"))
    let r5 = sync.syncNow(force: true)
    let f1 = read(mac, "notes/f1.md")
    let f1Lines = f1.components(separatedBy: "\n")
    let opener = f1Lines.firstIndex { $0.hasPrefix("<<<<<<<") } ?? -1, mid = f1Lines.firstIndex { $0 == "=======" } ?? -1
    check("a clash over the header and its closing line keeps both sides, one block across the fence",
          f1.contains("mac first") && f1.contains("other first") && opener >= 0 && mid > opener && f1Lines[opener..<mid].contains("---"), f1)
    check("it counts as a clash and reads as a whole-file body",
          r5.clashes >= 1 && NotesStore.parse(id: "f1", f1)?.conflicted == true && NotesStore.parse(id: "f1", f1)?.title == "f1")
    put(mac, "notes/f1.md", note("Fence", pos: "4", body: "settled")); sync.syncNow(force: true)

    // 10. an edit beats a delete, and the note is listed as come back
    put(mac, "notes/d1.md", note("Doomed", body: "v1")); sync.syncNow(force: true)
    g(other, "pull", "-q", "--no-rebase"); put(other, "notes/d1.md", note("Doomed", body: "v2 edited elsewhere")); otherSaves("other: edit d1")
    try? fm.removeItem(atPath: mac + "/notes/d1.md")
    let r6 = sync.syncNow(force: true)
    check("a delete against an edit keeps the note", read(mac, "notes/d1.md").contains("v2 edited elsewhere"), read(mac, "notes/d1.md"))
    check("the note is listed in cameBack, in the state and the file", r6.cameBack.contains("d1")
          && read(mac, ".git/mnt-sync-state.json").contains("\"d1\""), "\(r6.cameBack)")
    check("and that round was ok", r6.ok && r6.ahead == 0, "\(r6)")

    // 11. an unreachable remote: the save is still committed, the state says why and how old the copy is
    defaults.set("https://127.0.0.1:9/nobody/nothing.git", forKey: NotesSync.remoteKey)
    put(mac, "notes/offline.md", note("Offline", body: "written with no network"))
    let r7 = sync.syncNow(force: true)
    check("an unreachable remote still commits locally", sync.history(of: "offline").count == 1)
    check("the state names the problem in words, with how old the copy is and what waits",
          !r7.ok && r7.problem?.contains("could not be reached") == true && r7.problem?.contains("last sync") == true
          && r7.problem?.contains("waiting to go up") == true, r7.problem ?? "nil")
    check("the failure is in the state file for other apps", read(mac, ".git/mnt-sync-state.json").contains("\"ok\": false"))
    let tick = sync.syncNow(force: false)
    check("a tick after a failure keeps saying so rather than clearing it", !tick.ok, "\(tick)")
    defaults.set(bare, forKey: NotesSync.remoteKey)
    let r8 = sync.syncNow(force: true)
    check("when the remote returns the next round catches up and clears the problem", r8.ok && r8.ahead == 0 && r8.problem == nil, "\(r8)")
    defaults.removeObject(forKey: NotesSync.remoteKey)

    // 12. the lock: a writer waits up to five seconds, then says so; nested use does not deadlock
    check("holding the lock again inside it does not wait", sync.withLock(busy: -1, { sync.git(["status", "-s"]).code }) == 0)
    let fd = open(mac + "/.git/mnt-sync.lock", O_CREAT | O_RDWR, 0o644)
    flock(fd, LOCK_EX)
    let t0 = Date()
    let busy = sync.git(["status", "-s"])
    let waited = Date().timeIntervalSince(t0)
    flock(fd, LOCK_UN); close(fd)
    check("another holder of the lock makes git wait about five seconds and then refuse in words",
          busy.code == 75 && waited >= 4.5 && waited < 8 && busy.err.contains("Another tool"), "\(busy.code) after \(waited)s")
    check("once released git runs again", sync.git(["status", "-s"]).code == 0)

    // 13. a merge left half done is finished by the next round
    g(other, "pull", "-q", "--no-rebase"); put(other, "notes/half.md", note("Half", body: "other")); otherSaves("other: half")
    put(mac, "notes/half.md", note("Half", body: "mac")); sync.commitNow("save")
    g(mac, "fetch", "-q", "origin")
    g(mac, "merge", "-q", "--no-edit", "origin/main")
    check("the scratch merge is left unfinished", fm.fileExists(atPath: mac + "/.git/MERGE_HEAD"))
    let r9 = sync.syncNow(force: true)
    check("the next round finishes it, keeping both sides", !fm.fileExists(atPath: mac + "/.git/MERGE_HEAD") && r9.ok
          && read(mac, "notes/half.md").contains("<<<<<<<"), "\(r9)")
    return lines
}
