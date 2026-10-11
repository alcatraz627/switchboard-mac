// NotesSync.swift
// The notes folder as a git repository: every save becomes a commit, the Pi
// holds the remote, and a clash keeps both sides in the file with git's
// markers rather than waiting on anyone. Nothing here ever prompts: ssh runs in
// batch mode and a remote that does not answer is a line in the tab, not a
// hang. Contract: docs/plans/20261010-notes-contract.md

import Foundation

/// One saved version of a note: the commit's short hash, when it was made, and why.
struct NoteVersion: Identifiable, Equatable {
    let sha: String
    let when: Date
    let reason: String
    var id: String { sha }
}

final class NotesSync: ObservableObject {
    static let shared = NotesSync()
    /// The remote the Pi serves, e.g. `alcatraz627@100.65.188.9:Notes.git`; empty means local history only.
    static let remoteKey = "switchboard.notesRemote"
    static let remoteName = "pi"
    static let branch = "main"

    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// Why the last sync did not finish, in plain words, or nil.
    @Published private(set) var problem: String?
    /// How many notes hold both sides of a clash right now.
    @Published private(set) var conflicts = 0

    var remote: String { UserDefaults.standard.string(forKey: Self.remoteKey) ?? "" }
    var dir: String { NotesStore.dir }
    private var commitWork: DispatchWorkItem?
    private var pendingReason: String?
    private let queue = DispatchQueue(label: "switchboard.notes.git", qos: .utility)
    private var timer: Timer?

    /// Syncs on a timer, so an edit on the phone shows up without opening the panel.
    func start(every seconds: TimeInterval = 30) {   // owner: "a note anywhere is everywhere inside a minute"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.sync() }
        timer?.tolerance = 10
    }

    /// The folder becomes a repository the first time anything is saved into it.
    @discardableResult
    func ensureRepo() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else { return false }
        if fm.fileExists(atPath: dir + "/.git") { ignoreMigratedOrder(); return true }
        let r = git(["init", "-q", "-b", Self.branch])
        guard r.code == 0 else { problem = "git init failed: \(r.err)"; return false }
        _ = git(["config", "user.name", "Switchboard"])
        _ = git(["config", "user.email", "switchboard@local"])
        // .trash/ is bfb's local undo for deletes; the delete itself is what syncs.
        try? "order.json\norder.json.migrated*\n.DS_Store\n.import/\n.trash/\n".write(toFile: dir + "/.gitignore", atomically: true, encoding: .utf8)
        return true
    }

    /// A repository made before the order moved into `pos` lines keeps the set-aside order file out of history too.
    private func ignoreMigratedOrder() {
        let p = dir + "/.gitignore"
        guard let t = try? String(contentsOfFile: p, encoding: .utf8), !t.contains("order.json.migrated") else { return }
        try? (t.hasSuffix("\n") ? t : t + "\n").appending("order.json.migrated*\n").write(toFile: p, atomically: true, encoding: .utf8)
    }

    /// Sync now rather than at the next tick: a run aimed at the phone should not wait half a minute to leave.
    func syncSoon() {
        commitWork?.cancel()
        sync()
    }

    /// Commit what changed, a moment after the last save, so a burst of typing is one commit.
    func commit(_ reason: String) {
        commitWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pendingReason = nil; self?.commitNow(reason) }
        commitWork = w
        pendingReason = reason
        queue.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// Writes and commits a change on its own, at once: other devices ignore "move" commits for edit
    /// times, so typing still waiting is committed first under its own reason.
    func commitAlone(_ reason: String, write: () -> Void) {
        if let w = commitWork, let r = pendingReason {
            w.cancel()
            commitWork = nil
            pendingReason = nil
            queue.sync { commitNow(r) }
        }
        write()
        queue.sync { commitNow(reason) }
    }

    func commitNow(_ reason: String) {
        guard ensureRepo() else { return }
        _ = git(["add", "-A"])
        let r = git(["commit", "-q", "-m", reason])
        // nothing to commit is not a problem
        if r.code != 0, !r.err.contains("nothing to commit"), !r.out.contains("nothing to commit") {
            DispatchQueue.main.async { self.problem = "commit failed: \(r.err.isEmpty ? r.out : r.err)" }
        }
        readEditTimes()
    }

    /// When each note was last edited, by its last commit: a file's own time changes for
    /// every note a sync or checkout touches, so "edited lately" lit up on all of them.
    private(set) var editTimes: [String: Date] = [:]
    private let editLock = NSLock()
    private var editTimesRead = false
    func editTime(_ id: String) -> Date? {
        // the first reader before any commit reads the history once
        editLock.lock(); let read = editTimesRead; editLock.unlock()
        if !read { readEditTimes() }
        editLock.lock(); defer { editLock.unlock() }; return editTimes[id]
    }

    private func readEditTimes() {
        var times: [String: Date] = [:], when: Date?
        // newest first, so the first time a file appears is its last edit
        for line in git(["log", "--format=@%ct", "--name-only", "--", "*.md"]).out.split(separator: "\n") {
            if line.hasPrefix("@"), let t = TimeInterval(line.dropFirst()) { when = Date(timeIntervalSince1970: t) }
            else if line.hasSuffix(".md"), let w = when {
                let id = String(line.dropLast(3))
                if times[id] == nil { times[id] = w }
            }
        }
        editLock.lock(); editTimes = times; editTimesRead = true; editLock.unlock()
    }

    /// Pull the Pi's changes and push ours. A clash is committed with both sides kept.
    func sync() {
        let url = remote.trimmingCharacters(in: .whitespaces)
        guard !syncing else { return }
        // with no Pi to talk to, the timer still turns what other tools wrote (bfb, a hand edit) into versions
        if url.isEmpty {
            queue.async { [weak self] in
                self?.commitNow("save")
                DispatchQueue.main.async { if !NotesStore.probing { Runs.shared.reload() } }
            }
            return
        }
        syncing = true
        queue.async { [weak self] in
            guard let self else { return }
            self.commitNow("save")
            var failure: String?
            defer {
                // a failing sync was silent: the Settings line was the only trace, and nobody reads it unasked
                if let f = failure { dwarn("notes sync: \(f)") } else { dlog("notes sync: ok") }
                DispatchQueue.main.async {
                    self.syncing = false
                    self.problem = failure
                    if failure == nil { self.lastSync = Date() }
                    self.conflicts = Self.countConflicts(in: self.dir)
                    NotesStore.shared.loadInBackground()
                    // what the other device wrote, read now that the sync landed
                    if !NotesStore.probing { Runs.shared.reload() }
                }
            }
            if self.git(["remote", "get-url", Self.remoteName]).out.trimmingCharacters(in: .whitespacesAndNewlines) != url {
                _ = self.git(["remote", "remove", Self.remoteName])
                _ = self.git(["remote", "add", Self.remoteName, url])
            }
            let fetch = self.git(["fetch", "-q", Self.remoteName, Self.branch])
            guard fetch.code == 0 else { failure = "the Pi did not answer: \(fetch.err.components(separatedBy: "\n").first ?? "")"; return }
            // the Pi's folder starts with its own first commit (the import), so the first merge joins two histories
            let merge = self.git(["merge", "-q", "--no-edit", "--allow-unrelated-histories", "\(Self.remoteName)/\(Self.branch)"])
            if merge.code != 0 {
                // a clash over order or the run folder takes this Mac's side; any other keeps both, marked, and the row shows it
                Self.settleClashes(in: self.dir, git: { self.git($0) })
                _ = self.git(["add", "-A"])
                _ = self.git(["commit", "-q", "-m", "merge: both sides kept"])
            }
            let push = self.git(["push", "-q", Self.remoteName, "HEAD:\(Self.branch)"])
            if push.code != 0 { failure = "push failed: \(push.err.components(separatedBy: "\n").first ?? "")" }
        }
    }

    /// The versions of one note, newest first.
    func history(of id: String) -> [NoteVersion] {
        let r = git(["log", "--format=%h%x09%ct%x09%s", "--", id + ".md"])
        return r.out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard p.count == 3, let t = TimeInterval(p[1]) else { return nil }
            return NoteVersion(sha: p[0], when: Date(timeIntervalSince1970: t), reason: p[2])
        }
    }

    /// The note's text at one version.
    func version(of id: String, at sha: String) -> String? {
        let r = git(["show", "\(sha):\(id).md"])
        return r.code == 0 ? r.out : nil
    }

    /// A body that holds git's clash markers.
    static func conflicted(_ text: String) -> Bool {
        text.hasPrefix("<<<<<<< ") || text.contains("\n<<<<<<< ")
    }

    enum Keep { case mine, theirs, both }

    /// The text with every clash block settled: the first side (this Mac's), the second
    /// (the Pi's or the phone's), or both, mine first. Text outside the blocks is kept as is.
    static func resolve(_ text: String, keep: Keep) -> String {
        var out: [Substring] = [], mine: [Substring] = [], theirs: [Substring] = []
        enum Part { case outside, mine, theirs }
        var part = Part.outside
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            switch part {
            case .outside where line.hasPrefix("<<<<<<< ") || line == "<<<<<<<": part = .mine; mine = []; theirs = []
            case .outside: out.append(line)
            case .mine where line == "=======": part = .theirs
            case .mine: mine.append(line)
            case .theirs where line.hasPrefix(">>>>>>> ") || line == ">>>>>>>":
                part = .outside
                out += keep == .theirs ? theirs : keep == .mine ? mine : mine + theirs
            case .theirs: theirs.append(line)
            }
        }
        // an unclosed block keeps everything it held, so nothing is lost
        if part != .outside { out += mine + theirs }
        return out.joined(separator: "\n")
    }

    /// True when every clash in the text is only a `pos:` line (the same note moved on two devices).
    static func posOnlyClash(_ text: String) -> Bool {
        var blocks = 0, part = 0   // 0 outside, 1 first side, 2 second side
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            switch part {
            case 0 where line.hasPrefix("<<<<<<< ") || line == "<<<<<<<": part = 1; blocks += 1
            case 0: break
            case 1 where line == "=======": part = 2
            case 2 where line.hasPrefix(">>>>>>> ") || line == ">>>>>>>": part = 0
            default: if !line.hasPrefix("pos:") { return false }
            }
        }
        return blocks > 0 && part == 0
    }

    /// After a merge that stopped on clashes: the notes' `pos` clashes and anything under `.reminders/` keep
    /// this Mac's side (a lost move or run request is cheap), everything else is left for both-sides-kept.
    static func settleClashes(in dir: String, git: ([String]) -> (code: Int32, out: String, err: String)) {
        let unmerged = git(["diff", "--name-only", "--diff-filter=U"]).out.split(separator: "\n").map(String.init)
        for path in unmerged {
            if path.hasPrefix(".reminders/") {
                if git(["checkout", "--ours", "--", path]).code != 0 { _ = git(["rm", "-q", "-f", "--", path]) }
            } else if path.hasSuffix(".md"), let text = try? String(contentsOfFile: dir + "/" + path, encoding: .utf8), posOnlyClash(text) {
                try? resolve(text, keep: .mine).write(toFile: dir + "/" + path, atomically: true, encoding: .utf8)
            }
        }
    }

    static func countConflicts(in dir: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".md") }
            .filter { conflicted((try? String(contentsOfFile: dir + "/" + $0, encoding: .utf8)) ?? "") }.count
    }

    /// One git call in the notes folder, never interactive, 20 s at most.
    @discardableResult
    func git(_ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (127, "", error.localizedDescription) }
        let deadline = DispatchTime.now() + 20
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: deadline) == .timedOut { p.terminate(); return (124, "", "git \(args.first ?? "") timed out") }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, o, e)
    }
}

// ── Probe ───────────────────────────────────────────────────────────────────

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
    try? "---\ntitle: clash\n---\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> pi/main\n".write(toFile: NotesStore.dir + "/clash.md", atomically: true, encoding: .utf8)
    check("a file holding both sides counts as a clash", NotesSync.countConflicts(in: NotesStore.dir) == 1)
    s.load()
    check("the clash shows on the note", s.notes.first { $0.id == "clash" }?.conflicted == true)
    try? FileManager.default.removeItem(atPath: NotesStore.dir + "/clash.md")
    // with no remote set, the timer's sync still turns a file another tool wrote into a version
    UserDefaults.standard.removeObject(forKey: NotesSync.remoteKey)
    try? "---\ntitle: by hand\n---\nwritten by another tool\n".write(toFile: NotesStore.dir + "/byhand.md", atomically: true, encoding: .utf8)
    sync.sync()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    check("a file another tool wrote becomes a version on the next tick, remote or not",
          sync.history(of: "byhand").count == 1, "\(sync.history(of: "byhand").count)")
    UserDefaults.standard.set("nobody@203.0.113.1:Notes.git", forKey: NotesSync.remoteKey)
    let r = sync.git(["ls-remote", "nobody@203.0.113.1:Notes.git"])
    check("a remote that does not answer fails fast with words, never a prompt", r.code != 0 && !r.err.isEmpty)
    UserDefaults.standard.removeObject(forKey: NotesSync.remoteKey)
    return lines + probeRuns()
}
