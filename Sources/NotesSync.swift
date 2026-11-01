// NotesSync.swift
// The notes folder as part of a git repository: every save becomes a commit, GitHub
// holds the shared copy, and a clash keeps both sides in the file with git's markers
// rather than waiting on anyone. The folder may be a subfolder of a larger clone, and
// only that subfolder is ever staged or listed. Nothing here ever prompts: git runs
// with its prompts off, and a remote that does not answer is a line in the Notes tab
// and in the menu-bar dot, never a hang. Written definition: mnt-sync/specs/notes.md

import Foundation

/// One saved version of a note: the commit's short hash, when it was made, and why.
struct NoteVersion: Identifiable, Equatable {
    let sha: String
    let when: Date
    let reason: String
    var id: String { sha }
}

/// Where the notes folder sits in git: the clone's top, its git directory, and the notes folder's
/// path inside the clone ("notes/", or empty when the folder is the clone's top).
struct NotesRepo: Equatable {
    let top: String
    let gitDir: String
    let prefix: String
    var lockPath: String { gitDir + "/mnt-sync.lock" }
    var statePath: String { gitDir + "/mnt-sync-state.json" }
}

/// What the last round of sync found, as other apps read it from `.git/mnt-sync-state.json`.
struct SyncState: Equatable {
    var at: Date
    var ok: Bool
    var problem: String?
    var ahead: Int
    var behind: Int
    var clashes: Int
    var cameBack: [String]
    var lastOk: Date?

    /// The file's text, keys in the order the spec shows them.
    var json: String {
        func s(_ v: String?) -> String {
            guard let v else { return "null" }
            let d = try? JSONSerialization.data(withJSONObject: [v], options: [.withoutEscapingSlashes])
            return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "null"
        }
        let iso = ISO8601DateFormatter()
        return "{\"at\": \(s(iso.string(from: at))), \"ok\": \(ok), \"problem\": \(s(problem)), \"ahead\": \(ahead), "
            + "\"behind\": \(behind), \"clashes\": \(clashes), \"cameBack\": [\(cameBack.map { s($0) }.joined(separator: ", "))], "
            + "\"lastOk\": \(s(lastOk.map { iso.string(from: $0) }))}\n"
    }
}

typealias GitResult = (code: Int32, out: String, err: String)

final class NotesSync: ObservableObject {
    static let shared = NotesSync()
    /// The GitHub address the notes folder syncs with, e.g. `https://github.com/alcatraz627/mnt-sync.git`.
    /// Empty means "use the clone's own `origin`", and with neither the notes stay on this Mac.
    /// A run on a scratch state folder (probes, snapshots) gets its own key: the defaults domain is shared
    /// with the owner's running app, which would otherwise adopt a test remote for the real notes.
    static let remoteKey = ProcessInfo.processInfo.environment["SWITCHBOARD_STATE"] == nil
        ? "switchboard.notesRemote" : "switchboard.notesRemote.scratch"
    /// Posted on the main thread after every round, so the menu-bar dot can follow the sync.
    static let changed = Notification.Name("switchboard.notesSyncChanged")
    static let remoteName = "origin"
    static let branch = "main"
    /// How long a writer waits for the folder's lock before giving up, as the spec says.
    static let lockWait: TimeInterval = 5
    /// A fetch about once a minute; the timer ticks twice as often so a save is pushed soon after it is committed.
    static let fetchEvery: TimeInterval = 55

    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// Why the copy is not in step with GitHub, in plain words and with how old it is, or nil.
    @Published private(set) var problem: String?
    /// How many notes hold both sides of a clash right now.
    @Published private(set) var conflicts = 0
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    /// Notes that were deleted on one device and edited on another, so the merge kept them.
    @Published private(set) var cameBack: [String] = []
    /// The clone's own `origin`, when the Settings key is empty.
    @Published private(set) var discoveredOrigin = ""

    var configuredRemote: String { (NotesStore.defaults.string(forKey: Self.remoteKey) ?? "").trimmingCharacters(in: .whitespaces) }
    var remote: String { configuredRemote.isEmpty ? discoveredOrigin : configuredRemote }
    var dir: String { NotesStore.dir }
    private var commitWork: DispatchWorkItem?
    private var pendingReason: String?
    private let queue = DispatchQueue(label: "switchboard.notes.git", qos: .utility)
    private var timer: Timer?

    // round bookkeeping, touched only on `queue`
    private var lastFetchAt = Date.distantPast
    private var netProblem: String?
    private var lastOk: Date?
    private var refusedRounds = 0
    private var cameBackAt: [String: Date] = [:]
    private var cameBackSeeded = false
    private(set) var lastState: SyncState?

    /// Syncs on a timer, so an edit on the phone shows up without opening the panel.
    func start(every seconds: TimeInterval = 30) {   // owner: "a note anywhere is everywhere inside a minute"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.sync(force: false) }
        timer?.tolerance = 10
    }

    // ── Finding the repository ──────────────────────────────────────────────

    private let repoLock = NSLock()
    private var repoCache: (dir: String, repo: NotesRepo)?

    /// The repository holding the notes folder, found in the folder or any folder above it.
    func repo() -> NotesRepo? {
        let d = dir
        repoLock.lock()
        if let c = repoCache, c.dir == d, FileManager.default.fileExists(atPath: c.repo.gitDir) { repoLock.unlock(); return c.repo }
        repoLock.unlock()
        guard FileManager.default.fileExists(atPath: d) else { return nil }
        let r = Self.runGit(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--show-prefix"], cwd: d)
        guard r.code == 0 else { return nil }
        let parts = r.out.components(separatedBy: "\n")
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let found = NotesRepo(top: parts[0], gitDir: parts[1], prefix: parts.count > 2 ? parts[2] : "")
        repoLock.lock(); repoCache = (d, found); repoLock.unlock()
        return found
    }

    private func forgetRepo() { repoLock.lock(); repoCache = nil; repoLock.unlock() }

    /// The folder is in a repository from the first time anything is saved into it. A folder inside an
    /// existing clone uses that clone; only a folder with no repository anywhere above it gets its own.
    @discardableResult
    func ensureRepo() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else { return false }
        if repo() != nil { ensureIgnores(fresh: false); return true }
        let r = Self.runGit(["init", "-q", "-b", Self.branch], cwd: dir)
        guard r.code == 0 else { setProblem("git init failed: \(r.err)"); return false }
        forgetRepo()
        _ = git(["config", "user.name", "Switchboard"])
        _ = git(["config", "user.email", "switchboard@local"])
        ensureIgnores(fresh: true)
        return repo() != nil
    }

    /// `.trash/` is bfb's local undo for deletes (the delete itself is what syncs), and the set-aside order file
    /// from the old order format stays out of history too.
    private func ensureIgnores(fresh: Bool) {
        let p = dir + "/.gitignore"
        let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
        if text.isEmpty {
            let base = fresh ? "order.json\n.DS_Store\n.import/\n" : ""
            try? (base + "order.json.migrated*\n.trash/\n").write(toFile: p, atomically: true, encoding: .utf8)
            return
        }
        let have = Set(text.split(separator: "\n").map(String.init))
        let missing = ["order.json.migrated*", ".trash/"].filter { !have.contains($0) }
        if missing.isEmpty { return }
        try? ((text.hasSuffix("\n") ? text : text + "\n") + missing.joined(separator: "\n") + "\n").write(toFile: p, atomically: true, encoding: .utf8)
    }

    private func setProblem(_ text: String?) { DispatchQueue.main.async { self.problem = text } }

    // ── Committing ──────────────────────────────────────────────────────────

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
            queue.sync { _ = commitNow(r) }
        }
        locked { write() }
        queue.sync { _ = commitNow(reason) }
    }

    /// Stages and commits only the notes folder, never anything else in the clone. Returns why it failed, or nil.
    @discardableResult
    func commitNow(_ reason: String) -> String? {
        guard ensureRepo() else { return nil }
        let failure: String? = withLock(busy: Self.busyText) {
            let add = git(["add", "-A", "--", "."])
            if add.code != 0 { return "could not stage the notes: \(add.err.isEmpty ? add.out : add.err)" }
            let r = git(["commit", "-q", "-m", reason, "--", "."])
            // nothing to commit is not a problem
            if r.code != 0, !r.err.contains("nothing to commit"), !r.out.contains("nothing to commit"),
               !r.out.contains("no changes added") {
                return "commit failed: \(r.err.isEmpty ? r.out : r.err)"
            }
            return nil
        }
        if let f = failure { setProblem(f) }
        readEditTimes()
        return failure
    }

    /// When each note was last edited, by its last commit: a file's own time changes for
    /// every note a sync or checkout touches, so "edited lately" lit up on all of them.
    private(set) var editTimes: [String: Date] = [:]
    private let editLock = NSLock()
    private var editTimesDir: String?
    func editTime(_ id: String) -> Date? {
        // the first reader before any commit reads the history once
        editLock.lock(); let read = editTimesDir == dir; editLock.unlock()
        if !read { readEditTimes() }
        editLock.lock(); defer { editLock.unlock() }; return editTimes[id]
    }

    private func readEditTimes() {
        var times: [String: Date] = [:], when: Date?
        let d = dir
        // newest first, so the first time a file appears is its last edit; paths relative to the notes folder
        for line in git(["log", "--format=@%ct", "--name-only", "--relative", "--", "*.md"]).out.split(separator: "\n") {
            if line.hasPrefix("@"), let t = TimeInterval(line.dropFirst()) { when = Date(timeIntervalSince1970: t) }
            else if line.hasSuffix(".md"), !line.contains("/"), let w = when {
                let id = String(line.dropLast(3))
                if times[id] == nil { times[id] = w }
            }
        }
        editLock.lock(); editTimes = times; editTimesDir = d; editLock.unlock()
    }

    // ── One round of sync ───────────────────────────────────────────────────

    /// Commit what changed, then (about once a minute, or when asked) fetch, merge and push.
    /// `force` is for the panel opening, a Settings button and a run aimed at the phone.
    func sync(force: Bool = true) {
        guard !syncing else { return }
        syncing = true
        queue.async { [weak self] in
            guard let self else { return }
            let state = self.syncNow(force: force)
            if let p = state.problem { dwarn("notes sync: \(p)") } else if force { dlog("notes sync: ok") }
            DispatchQueue.main.async {
                self.syncing = false
                NotesStore.shared.loadInBackground()
                // what the other device wrote, read now that the sync landed
                if !NotesStore.probing { Runs.shared.reload() }
            }
        }
    }

    /// The round itself, on the calling thread. Never stops on a clash, and a fetch that fails still
    /// leaves the local commit done.
    @discardableResult
    func syncNow(force: Bool) -> SyncState {
        // a merge the app quit in the middle of is finished first, since nothing else can commit until then
        if let repo = repo() { finishInterruptedMerge(repo) }
        let commitFailure = commitNow("save")
        var cameBackNow: [String] = []
        var originURL = ""

        if let repo = repo() {
            originURL = Self.runGit(["remote", "get-url", Self.remoteName], cwd: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let wanted = configuredRemote
            if !wanted.isEmpty, wanted != originURL {
                let r = originURL.isEmpty ? git(["remote", "add", Self.remoteName, wanted]) : git(["remote", "set-url", Self.remoteName, wanted])
                if r.code == 0 { originURL = wanted }
            }
            let url = originURL
            DispatchQueue.main.async { self.discoveredOrigin = url }
            if url.isEmpty {
                netProblem = "No GitHub address is set, so these notes are only on this Mac."
            } else {
                let due = force || Date().timeIntervalSince(lastFetchAt) >= Self.fetchEvery
                // after a failure the network is tried only on the minute, so a dead connection costs one wait, not two
                let tryNet = due || netProblem == nil
                if tryNet {
                    let r = networkRound(repo, fetch: due, cameBack: &cameBackNow)
                    if due { lastFetchAt = Date() }
                    // a tick with nothing to push never reached GitHub, so it neither clears a problem nor counts as a sync
                    if r.touched || due { netProblem = r.problem }
                    if r.problem == nil, r.touched || due { lastOk = Date() }
                }
            }
        } else {
            netProblem = "The notes folder is not in a git repository."
        }
        return publish(commitFailure: commitFailure, cameBackNow: cameBackNow, hasRemote: !originURL.isEmpty)
    }

    /// Fetch, merge what came, push what is ahead. `touched` says whether GitHub was actually asked;
    /// `problem` is the plain-words reason it failed, or nil.
    private func networkRound(_ repo: NotesRepo, fetch: Bool, cameBack out: inout [String]) -> (problem: String?, touched: Bool) {
        let origin = Self.remoteName, branch = Self.branch, remoteRef = "\(origin)/\(branch)"
        var remoteEmpty = false
        var touched = false
        if fetch {
            touched = true
            let f = Self.runGit(["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=15", "fetch", "-q", origin,
                                 "+refs/heads/\(branch):refs/remotes/\(remoteRef)"], cwd: dir, timeout: 45)
            if f.code != 0 {
                if f.err.contains("couldn't find remote ref") { remoteEmpty = true }
                else { return (Self.plainNetworkProblem(f.err, doing: "fetch"), true) }
            }
        }
        let haveRemoteRef = !remoteEmpty && git(["rev-parse", "-q", "--verify", "refs/remotes/\(remoteRef)"]).code == 0
        let behind = haveRemoteRef ? Int(git(["rev-list", "--count", "HEAD..\(remoteRef)"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        if behind > 0 {
            var refusal: String?
            func merge() -> [String] {
                let before = git(["rev-parse", "-q", "--verify", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
                let m = git(["merge", "-q", "--no-edit", remoteRef])
                var came: [String] = []
                if m.code != 0 {
                    guard FileManager.default.fileExists(atPath: repo.gitDir + "/MERGE_HEAD") else {
                        refusal = Self.plainMergeRefusal(m.err + m.out)
                        return []
                    }
                    came = settleAndCommitMerge(repo)
                }
                if !before.isEmpty { recordArrivals(since: before) }
                return came
            }
            let busy: () -> [String] = { refusal = Self.busyText; return [] }
            out = withLock(busy: busy(), merge)
            if let r = refusal { return (r, touched) }
        }
        let ahead = Int(git(["rev-list", "--count", haveRemoteRef ? "\(remoteRef)..HEAD" : "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if ahead > 0 {
            touched = true
            let p = Self.runGit(["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=15", "push", "-q", origin, "HEAD:refs/heads/\(branch)"],
                                cwd: dir, timeout: 45)
            if p.code != 0 {
                let e = p.err.lowercased()
                if e.contains("rejected"), e.contains("fetch first") || e.contains("non-fast-forward") || e.contains("stale info") {
                    // another device wrote between the fetch and the push: wait for the next round
                    refusedRounds += 1
                    return (refusedRounds >= 3
                            ? "GitHub keeps turning back this Mac's changes because another device keeps writing. It will try again."
                            : nil, true)
                }
                return (Self.plainNetworkProblem(p.err, doing: "push"), true)
            }
        }
        refusedRounds = 0
        return (nil, touched)
    }

    /// The notes and saves a merge added (not written on this Mac), handed to the inbox with a notification.
    /// `before` is where HEAD stood before the merge, so only what the other side brought is listed.
    func recordArrivals(since before: String) {
        let added = git(["diff", "--name-only", "--diff-filter=A", "--relative", before, "HEAD", "--", "."]).out
            .split(separator: "\n").map(String.init)
        let ids = NotesInbox.arrivalIDs(fromNames: added)
        guard !ids.isEmpty else { return }
        NotesInbox.shared.ingest(ids: ids, dir: dir, author: { id in
            let r = self.git(["log", "--diff-filter=A", "--format=%an", "-1", "\(before)..HEAD", "--", "./\(id).md"])
            let name = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : Self.deviceWord(name)
        })
    }

    /// A commit author as a short word for where it came from: "the phone", or the name as given.
    static func deviceWord(_ author: String) -> String {
        let a = author.lowercased()
        if a.contains("phone") || a.contains("android") || a.contains("csync") { return "the phone" }
        if a.contains("github") { return "another device" }
        return author
    }

    /// After a merge that stopped on clashes: settle what the rules settle, keep both sides of the rest, and commit.
    /// Returns the notes that came back (deleted on one device, edited on the other).
    private func settleAndCommitMerge(_ repo: NotesRepo) -> [String] {
        let came = Self.settleClashes(in: dir, git: { self.git($0) })
        // another part of the clone (a folder that is not the notes) keeps its markers; the merge still has to finish
        let all = Self.runGit(["ls-files", "-u"], cwd: repo.top).out.split(separator: "\n").compactMap { line -> String? in
            let p = line.split(separator: "\t", maxSplits: 1)
            return p.count == 2 ? String(p[1]) : nil
        }
        let outside = Array(Set(all.filter { !repo.prefix.isEmpty && !$0.hasPrefix(repo.prefix) }))
        if !outside.isEmpty { _ = Self.runGit(["add", "--"] + outside, cwd: repo.top) }
        _ = git(["commit", "-q", "-m", "merge: both sides kept"])
        return came
    }

    /// A merge left half done (the app quit during it) is finished the same way before anything else runs.
    private func finishInterruptedMerge(_ repo: NotesRepo) {
        guard FileManager.default.fileExists(atPath: repo.gitDir + "/MERGE_HEAD") else { return }
        withLock(busy: ()) { _ = settleAndCommitMerge(repo); return () }
    }

    /// Counts, state file and the values the app shows, after every round.
    private func publish(commitFailure: String?, cameBackNow: [String], hasRemote: Bool) -> SyncState {
        let now = Date()
        // came-back notes stay listed for a day, or until the note is gone
        if !cameBackSeeded, let repo = repo() {
            cameBackSeeded = true
            if let data = FileManager.default.contents(atPath: repo.statePath),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ids = o["cameBack"] as? [String] {
                for id in ids { cameBackAt[id] = now }
            }
        }
        for id in cameBackNow { cameBackAt[id] = now }
        for (id, t) in cameBackAt where now.timeIntervalSince(t) > 86_400 || !FileManager.default.fileExists(atPath: dir + "/" + id + ".md") {
            cameBackAt[id] = nil
        }
        let came = cameBackAt.keys.sorted()

        let remoteRef = "refs/remotes/\(Self.remoteName)/\(Self.branch)"
        let haveRef = git(["rev-parse", "-q", "--verify", remoteRef]).code == 0
        func count(_ range: String) -> Int { Int(git(["rev-list", "--count", range]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        let aheadN = hasRemote ? (haveRef ? count("\(remoteRef)..HEAD") : count("HEAD")) : 0
        let behindN = haveRef ? count("HEAD..\(remoteRef)") : 0
        let clashes = Self.countConflicts(in: dir)

        var words = commitFailure ?? netProblem
        if let w = words, commitFailure == nil, hasRemote {
            // how stale the copy is, in the same sentence as what is wrong
            var tail = lastOk.map { " The last sync was \(age($0))." } ?? " It has not synced yet."
            if aheadN > 0 { tail += aheadN == 1 ? " 1 save is waiting to go up." : " \(aheadN) saves are waiting to go up." }
            words = w + tail
        }
        let state = SyncState(at: now, ok: words == nil, problem: words, ahead: aheadN, behind: behindN, clashes: clashes,
                              cameBack: came, lastOk: lastOk)
        lastState = state
        if let repo = repo() { try? Data(state.json.utf8).write(to: URL(fileURLWithPath: repo.statePath), options: .atomic) }
        DispatchQueue.main.async {
            self.problem = state.problem
            self.lastSync = state.lastOk
            self.ahead = aheadN; self.behind = behindN
            self.conflicts = clashes
            self.cameBack = came
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        return state
    }

    /// For a picture of the failure line (`--snapshot --demo-sync-failure`, scratch state folder only): a real
    /// round against an origin that refuses connections, so the words come from the same code the app runs.
    func demoFailure() {
        guard ProcessInfo.processInfo.environment["SWITCHBOARD_STATE"] != nil, ensureRepo() else { return }
        _ = git(["remote", "add", Self.remoteName, "https://127.0.0.1:9/demo/notes.git"])
        try? "---\ntitle: \"Saved while offline\"\n---\nthis one is waiting to go up\n".write(toFile: dir + "/offline-demo.md", atomically: true, encoding: .utf8)
        let state = syncNow(force: true)
        problem = state.problem
        ahead = state.ahead
    }

    // ── Plain words for what git said ───────────────────────────────────────

    static func plainNetworkProblem(_ err: String, doing: String) -> String {
        let e = err.lowercased()
        let first = err.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if e.contains("authentication failed") || e.contains("could not read username") || e.contains("could not read password")
            || e.contains("invalid username") || e.contains("permission denied") || e.contains("403") {
            return "GitHub did not accept this Mac's sign-in."
        }
        if e.contains("repository not found") || e.contains("not found") || e.contains("does not appear to be a git repository") {
            return "GitHub says that repository is not there, or this Mac may not read it."
        }
        if e.contains("could not resolve host") || e.contains("failed to connect") || e.contains("timed out") || e.contains("timeout")
            || e.contains("network is unreachable") || e.contains("connection") || e.contains("unable to access") || e.contains("slow") {
            return "GitHub could not be reached."
        }
        return "GitHub gave an error on the \(doing): \(first)"
    }

    static func plainMergeRefusal(_ text: String) -> String {
        let t = text.lowercased()
        if t.contains("unrelated histories") { return "GitHub's copy shares no history with this one, so it was not merged. Check the address in Settings." }
        if t.contains("would be overwritten") { return "A change made outside Switchboard stopped the merge. Commit or put it aside in the clone." }
        let first = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return "The merge with GitHub did not finish: \(first)"
    }

    static let busyText = "Another tool was using the notes folder, so this round waited and gave up. It will try again."

    // ── History ─────────────────────────────────────────────────────────────

    /// The versions of one note, newest first.
    func history(of id: String) -> [NoteVersion] {
        let r = git(["log", "--format=%h%x09%ct%x09%s", "--", id + ".md"])
        return r.out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard p.count == 3, let t = TimeInterval(p[1]) else { return nil }
            return NoteVersion(sha: p[0], when: Date(timeIntervalSince1970: t), reason: p[2])
        }
    }

    /// The note's text at one version. `./` makes the path relative to the notes folder, inside a clone.
    func version(of id: String, at sha: String) -> String? {
        let r = git(["show", "\(sha):./\(id).md"])
        return r.code == 0 ? r.out : nil
    }

    // ── Clashes ─────────────────────────────────────────────────────────────

    /// A file holds a clash when any line starts with `<<<<<<< ` or is exactly `<<<<<<<`, anywhere in it:
    /// the header and a block across the closing fence count.
    static func conflicted(_ text: String) -> Bool {
        guard text.contains("<<<<<<<") else { return false }
        let t = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        return t.split(separator: "\n", omittingEmptySubsequences: true).contains { $0.hasPrefix("<<<<<<< ") || $0 == "<<<<<<<" }
    }

    enum Keep { case mine, theirs, both }

    /// The text with every clash block settled: the first side (this Mac's), the second
    /// (another device's or the phone's), or both, mine first. Text outside the blocks is kept as is.
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

    /// After a merge that stopped on clashes, run from inside the notes folder (every path is relative to it):
    /// a `pos` clash and anything under `.reminders/` take this Mac's side (a lost move or run request is cheap),
    /// a note deleted on one side and edited on the other keeps the edit, and any other clash in a note keeps
    /// both sides, marked. Files that are not notes (tag colours, pictures) cannot hold markers, so they take
    /// this Mac's side. Returns the ids of the notes that came back.
    @discardableResult
    static func settleClashes(in dir: String, git: ([String]) -> GitResult) -> [String] {
        var stages: [String: Set<Int>] = [:]
        for line in git(["ls-files", "-u", "--", "."]).out.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 1)
            guard p.count == 2, let st = p[0].split(separator: " ").last.flatMap({ Int($0) }) else { continue }
            stages[String(p[1]), default: []].insert(st)
        }
        var came: [String] = []
        for path in stages.keys.sorted() {
            let st = stages[path] ?? []
            let exists = FileManager.default.fileExists(atPath: dir + "/" + path)
            let oneSideDeleted = !(st.contains(2) && st.contains(3))
            if path.hasPrefix(".reminders/") {
                if git(["checkout", "--ours", "--", path]).code != 0 { _ = git(["rm", "-q", "-f", "--", path]) } else { _ = git(["add", "--", path]) }
            } else if path.hasSuffix(".md") {
                if oneSideDeleted {
                    // an edit beats a delete: the file git left in the folder is the edited one
                    if exists { _ = git(["add", "--", path]); if !path.contains("/") { came.append(String(path.dropLast(3))) } }
                    else { _ = git(["rm", "-q", "-f", "--", path]) }
                } else {
                    if let text = try? String(contentsOfFile: dir + "/" + path, encoding: .utf8), posOnlyClash(text) {
                        try? resolve(text, keep: .mine).write(toFile: dir + "/" + path, atomically: true, encoding: .utf8)
                    }
                    _ = git(["add", "--", path])
                }
            } else if oneSideDeleted {
                _ = git(exists ? ["add", "--", path] : ["rm", "-q", "-f", "--", path])
            } else {
                _ = git(["checkout", "--ours", "--", path]); _ = git(["add", "--", path])
            }
        }
        return came
    }

    static func countConflicts(in dir: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".md") }
            .filter { conflicted((try? String(contentsOfFile: dir + "/" + $0, encoding: .utf8)) ?? "") }.count
    }

    // ── The lock ────────────────────────────────────────────────────────────

    private static let depthKey = "switchboard.notes.lockdepth"

    private func acquire(_ repo: NotesRepo) -> Int32? {
        let fd = open(repo.lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { close(fd); return nil }
            usleep(50_000)
        }
        return fd
    }

    /// Runs `body` holding the folder's lock (`.git/mnt-sync.lock`), waiting up to five seconds for it; every
    /// other tool that writes in the clone takes the same lock. If it stays busy, `busy` answers instead and
    /// `body` does not run. Holding it again from inside `body` on the same thread is free.
    func withLock<T>(busy: @autoclosure () -> T, _ body: () throws -> T) rethrows -> T {
        let dict = Thread.current.threadDictionary
        let depth = (dict[Self.depthKey] as? Int) ?? 0
        if depth > 0 {
            dict[Self.depthKey] = depth + 1
            defer { dict[Self.depthKey] = depth }
            return try body()
        }
        guard let repo = repo() else { return try body() }
        guard let fd = acquire(repo) else { return busy() }
        dict[Self.depthKey] = 1
        defer { dict[Self.depthKey] = 0; flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    /// For a writer of files in the notes folder (a note, a run file): holds the lock around the write.
    /// If the lock stays busy for five seconds the write goes ahead anyway, so words are never lost to a wait.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        var ran = false
        let r: T? = try withLock(busy: nil) { ran = true; return Optional(try body()) }
        if ran, let r { return r }
        dwarn("notes lock busy for \(Int(Self.lockWait)) s; writing without it")
        return try body()
    }

    // ── Running git ─────────────────────────────────────────────────────────

    /// One git call in the notes folder, never interactive, 20 s at most, inside the lock.
    @discardableResult
    func git(_ args: [String]) -> GitResult {
        withLock(busy: (75, "", Self.busyText)) { Self.runGit(args, cwd: dir) }
    }

    private final class Collected { var data = Data() }

    /// Runs /usr/bin/git. Both pipes are read while it runs, so output past the pipe's 64 KB cannot stall it.
    static func runGit(_ args: [String], cwd: String, timeout: TimeInterval = 20) -> GitResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=off"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX"] { env[k] = nil }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GCM_INTERACTIVE"] = "never"
        env["LC_ALL"] = "C"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (127, "", error.localizedDescription) }
        let o = Collected(), e = Collected(), readers = DispatchGroup()
        readers.enter(); DispatchQueue.global(qos: .utility).async { o.data = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        readers.enter(); DispatchQueue.global(qos: .utility).async { e.data = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return (124, "", "git \(args.first(where: { !$0.hasPrefix("-") && $0 != "core.quotepath=off" && !$0.contains("=") }) ?? "") timed out")
        }
        // a helper git started can hold the pipe open past git's own exit; do not wait on it for long
        _ = readers.wait(timeout: .now() + 3)
        return (p.terminationStatus, String(data: o.data, encoding: .utf8) ?? "", String(data: e.data, encoding: .utf8) ?? "")
    }
}
