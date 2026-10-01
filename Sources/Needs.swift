// Needs.swift
// The "Needs you" strip: everything an agent is waiting on the owner for (a
// push to a protected branch, an action behind an "ask" policy), shown above
// the tabs only while something waits.
//
// Every item gets Approve, Copy, Cancel and details that open below the row.
// Approve writes the same single-use file the typed approve line writes, then
// nudges the session over claude-ipc to retry. Owner ruling 2026-09-29, knowing
// an agent that drives the GUI could press it: "No fingerprint, single click
// only", and "everything should get a click to approve + copy + cancel + info".

import AppKit
import SwiftUI

struct NeedItem: Identifiable {
    enum Kind { case push, ask, armedApproval }
    let id: String            // the file that holds it
    let kind: Kind
    let title: String
    let sessionID: String
    let sessionDir: String?   // nil when the session has ended
    let since: Date?
    /// What the owner types to approve, or nil when there is nothing to approve.
    let approveLine: String?
    /// Files whose removal cancels it, the same ones the typed cancel removes.
    let files: [String]
    /// Approved and waiting for its session to take a turn and run it.
    var approved = false
    /// The single-use file its gate consumes; Approve writes it.
    var approvedFile: String? = nil
    /// When it was approved, from that file's date.
    var approvedAt: Date? {
        approvedFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }
    /// Everything known about it, for the details below the row.
    var details: [(String, String)] = []
}

enum NeedsYou {
    /// What the list amounts to, so a watcher can tell a real change from a re-read.
    static func signature(_ items: [NeedItem]) -> String {
        items.map { "\($0.id)|\($0.approved)|\($0.sessionDir ?? "-")" }.sorted().joined(separator: ";")
    }

    /// Where the gate files live; a probe points it at a scratch folder.
    static var rootOverride: String?
    private static var root: String { rootOverride ?? SwitchboardPaths.gccRoot }

    /// Everything waiting, oldest first.
    static func items() -> [NeedItem] {
        let fm = FileManager.default
        let live = Dictionary(LiveSessions.all().map { ($0.id, $0.cwd) }, uniquingKeysWith: { a, _ in a })
        func json(_ path: String) -> [String: Any]? {
            fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func since(_ o: [String: Any], _ path: String) -> Date? {
            (o["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? ((try? fm.attributesOfItem(atPath: path)[.creationDate]) as? Date)
        }
        var out: [NeedItem] = []

        for f in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where f.hasPrefix(".push-nonce-") {
            let path = root + "/" + f, sid = String(f.dropFirst(".push-nonce-".count))
            guard let o = json(path), let nonce = o["nonce"] as? String else { continue }
            let repo = ((o["target"] as? String) ?? "?") as NSString
            var item = NeedItem(id: path, kind: .push,
                                title: "Push \(repo.lastPathComponent)",
                                sessionID: sid, sessionDir: live[sid], since: since(o, path),
                                approveLine: "approve push \(nonce)",
                                files: [path, root + "/.push-approved-" + sid])
            item.approvedFile = root + "/.push-approved-" + sid
            item.approved = fm.fileExists(atPath: item.approvedFile!)
            item.details = [("Repository", (o["target"] as? String) ?? "?"), ("Why it is held", (o["why"] as? String) ?? ""),
                            ("Session", sid), ("Session folder", live[sid] ?? "ended"),
                            ("Held since", since(o, path).map(fullDate) ?? ""), ("Approve line", "approve push \(nonce)"),
                            ("Cancel line", "cancel push")].filter { !$0.1.isEmpty }
            out.append(item)
        }

        let askDir = root + "/.policy-ask"
        for f in (try? fm.contentsOfDirectory(atPath: askDir)) ?? [] where f.hasSuffix(".nonce") {
            let path = askDir + "/" + f
            guard let o = json(path), let nonce = o["nonce"] as? String, let key = o["key"] as? String else { continue }
            // Named <session>--<key>.nonce by guard-policy.sh.
            let sid = f.components(separatedBy: "--").first ?? ""
            let base = String(path.dropLast(".nonce".count))
            let what = (o["what"] as? String) ?? key
            var item = NeedItem(id: path, kind: .ask,
                                title: what.prefix(1).uppercased() + what.dropFirst(),
                                sessionID: sid, sessionDir: live[sid], since: since(o, path),
                                approveLine: "approve \(key) \(nonce)",
                                files: [path, base + ".approved"])
            item.approvedFile = base + ".approved"
            item.approved = fm.fileExists(atPath: base + ".approved")
            item.details = [("Action", what), ("Policy", key), ("Session", sid), ("Session folder", live[sid] ?? "ended"),
                            ("Held since", since(o, path).map(fullDate) ?? ""), ("Approve line", "approve \(key) \(nonce)"),
                            ("Cancel line", "deny \(key)")].filter { !$0.1.isEmpty }
            out.append(item)
        }

        // Approvals already typed whose session ended before using them. A session
        // with a held push already lists its approval file there, so it gets one row.
        let pushSessions = Set(out.filter { $0.kind == .push }.map(\.sessionID))
        for a in PushApprovals.armed(liveSessionIDs: Set(live.keys), root: root)
        where !a.sessionIsLive && !pushSessions.contains(a.sessionID) {
            out.append(NeedItem(id: root + "/" + a.file, kind: .armedApproval,
                                title: "Unused push approval", sessionID: a.sessionID, sessionDir: nil,
                                since: a.armedAt, approveLine: nil, files: [root + "/" + a.file],
                                details: [("Session", a.sessionID), ("Typed", a.armedAt.map(fullDate) ?? "?"),
                                          ("File", root + "/" + a.file)]))
        }
        return out.sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
    }

    /// Approve a held push: write the single-use file the push gate consumes,
    /// the same one the typed line writes. Returns what went wrong, or nil.
    static func approve(_ item: NeedItem) -> String? {
        guard let sentinel = item.approvedFile else { return "there is nothing to approve here" }
        guard FileManager.default.createFile(atPath: sentinel, contents: Data()) else {
            return "could not write \(sentinel)"
        }
        if !probing {
            _ = Services.shell("/bin/bash", [root + "/scripts/hooks/warn-log.sh", "--hook", item.kind == .push ? "push-gate" : "policy-ask",
                                             "--action", "panel-approved", "--heeded", "yes"], timeout: 5)
        }
        nudge(item, item.kind == .push
            ? "[push-gate] the owner approved \(item.title.lowercased()) from the Switchboard panel; the single-use approval is written. Re-run the same git push now."
            : "[policy-ask] the owner approved \(item.title.lowercased()) from the Switchboard panel; the single-use approval is written. Run the same call again now; it covers that one call.")
        return nil
    }

    /// Tell the waiting session what the owner decided, so it acts without
    /// waiting for the owner's next message. Sent as a request because the ipc
    /// inbox monitor wakes an idle session only for requests, queries and
    /// responses. Best effort: the gate trusts the files, never this message.
    private static func nudge(_ item: NeedItem, _ msg: String) {
        guard !probing else { return }
        let peers = Services.shell("/bin/zsh", ["-lc", "claude-ipc peers --by-session"], timeout: 8)
        guard let d = peers.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["peers"] as? [[String: Any]],
              let alias = (list.first { ($0["sessionId"] as? String) == item.sessionID }?["aliases"] as? [String])?.first
        else { dlog("approve: no ipc mailbox for \(item.sessionID); it will see the approval on its next prompt"); return }
        _ = Services.shell("/bin/zsh", ["-lc", "claude-ipc register switchboard-panel --service >/dev/null 2>&1"], timeout: 8)
        _ = Services.shell("/bin/zsh", ["-lc", "claude-ipc send --to \(shellQuote(alias)) --from switchboard-panel --kind request --reply-by none \(shellQuote(msg))"], timeout: 10)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Cancel: what typing "cancel push" or "deny <key>" does. Returns what
    /// went wrong, or nil.
    static func cancel(_ item: NeedItem) -> String? {
        for f in item.files where FileManager.default.fileExists(atPath: f) {
            do { try FileManager.default.removeItem(atPath: f) } catch {
                return "could not remove \((f as NSString).lastPathComponent): \(error.localizedDescription)"
            }
        }
        if item.sessionDir != nil {
            nudge(item, item.kind == .push
                ? "[push-gate] the owner cancelled \(item.title.lowercased()) from the Switchboard panel; the nonce and any approval are gone. Do not push."
                : "[policy-ask] the owner denied \(item.title.lowercased()) from the Switchboard panel. Do not retry it; carry on with the rest of the work.")
        }
        return nil
    }

    /// Set by the headless probe so it never messages a real session.
    static var probing = false

    /// The Approvals tab: live pushes and asks still waiting on the owner,
    /// those approved but not yet run, then what ended sessions left behind.
    /// Empty when nothing waits.
    static func groups(_ items: [NeedItem], refresh: @escaping () -> Void) -> [SystemGroup] {
        let live = items.filter { $0.sessionDir != nil && !$0.approved }
        let approved = items.filter { $0.sessionDir != nil && $0.approved }
        let dead = items.filter { $0.sessionDir == nil }
        var out: [SystemGroup] = []
        let pushes = live.filter { $0.kind == .push }, asks = live.filter { $0.kind != .push }
        if !pushes.isEmpty { out.append(SystemGroup(title: "Pushes", rows: itemRows(pushes, refresh: refresh))) }
        if !asks.isEmpty { out.append(SystemGroup(title: "Policy asks", rows: itemRows(asks, refresh: refresh))) }
        if !approved.isEmpty { out.append(SystemGroup(title: "Approved, waiting to run", rows: itemRows(approved, refresh: refresh))) }
        if !dead.isEmpty {
            var all = SystemRow(label: "Nothing will run these", state: .off,
                                note: "their session is gone; ask a live session to try again, then clear these",
                                tip: "An ended session cannot use an approval, so these have no Approve.")
            all.key = "needs-dead-all"
            all.showsBadge = false
            all.buttons = [clearAll(dead, refresh: refresh)]
            out.append(SystemGroup(title: "Left by ended sessions", rows: [all] + itemRows(dead, refresh: refresh)))
        }
        return out
    }

    /// Clears every item, carrying on past one that fails, and names each
    /// failure rather than stopping at the first.
    private static func clearAll(_ items: [NeedItem], refresh: @escaping () -> Void) -> RowButton {
        RowButton(label: "Cancel", kind: .run({
            let errs = items.compactMap { i in cancel(i).map { "\(i.title): \($0)" } }
            DispatchQueue.main.async(execute: refresh)
            return errs.isEmpty ? nil : "\(errs.count) of \(items.count) not cleared. " + errs.joined(separator: "; ")
        }), help: "Clear all \(items.count)", doing: "clear them",
           confirm: "Clear all \(items.count) left by ended sessions? Their held pushes and approvals are removed.")
    }

    private static func itemRows(_ items: [NeedItem], refresh: @escaping () -> Void) -> [SystemRow] {
        items.map { item in
            let where_ = item.sessionDir.map { "session in " + (($0 as NSString).lastPathComponent) } ?? "session ended"
            let when = item.since.map { " · " + age($0) } ?? ""
            let note: String
            switch item.kind {
            case .push, .ask:
                // Honest about the wake: a session with no inbox watcher sleeps
                // through the request and runs on its next message instead.
                note = item.approved
                    ? "approved\(item.approvedAt.map { " " + age($0) } ?? "") · the session was asked to run it; if it is idle, it runs on your next message to it"
                    : where_ + when
            case .armedApproval: note = "typed, never used; the session ended" + when
            }
            var r = SystemRow(label: item.title,
                              state: item.approved ? .ok : item.sessionDir == nil ? .off : .on(menuYellow), note: note,
                              tip: item.approveLine.map { "To approve, paste into that session: \($0)" } ?? "")
            r.key = item.id
            r.showsBadge = false
            if item.approvedFile != nil, item.sessionDir != nil, !item.approved {
                r.buttons.append(RowButton(label: "Approve", kind: .run({
                    let err = approve(item)
                    DispatchQueue.main.async(execute: refresh)
                    return err
                }), help: "Approve this one \(item.kind == .push ? "push" : "call"). The session is told to run it now.",
                   doing: "approve it"))
            }
            if let line = item.approveLine {
                r.buttons.append(RowButton(label: "Copy", kind: .copy(line),
                                           help: "Copy \"\(line)\" to paste into that session"))
            }
            r.children = item.details.enumerated().map { i, d in
                var c = SystemRow(label: d.0, state: .off, note: d.1, tip: d.1)
                c.key = item.id + "-detail-\(i)"
                c.showsBadge = false
                return c
            }
            r.buttons.append(RowButton(label: "Cancel", kind: .run({
                let err = cancel(item)
                DispatchQueue.main.async(execute: refresh)
                return err
            }), help: item.kind == .push ? "Same as typing: cancel push" : item.kind == .ask ? "Same as typing: deny" : "Revoke it",
               doing: "cancel it"))
            return r
        }
    }
}

extension PolicyStore {
    /// Publish what waits to the Approvals tab. The badge counts only what a
    /// live session is still waiting on you for; an approved item is not.
    func setNeeds(_ items: [NeedItem], refresh: @escaping () -> Void) {
        needGroups = NeedsYou.groups(items, refresh: refresh)
        needsWaiting = items.filter { $0.sessionDir != nil && !$0.approved }.count
    }
}

// ── Headless probe ──────────────────────────────────────────────────────────

/// Plants a held push in a scratch folder, approves it the way the button does,
/// and checks the approval file lands where the push gate reads it. Never
/// touches ~/.claude, so it cannot approve a real push.
func probeApprove() -> String {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "sb-approve-probe-\(getpid())"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    NeedsYou.rootOverride = dir
    NeedsYou.probing = true
    defer { NeedsYou.rootOverride = nil; NeedsYou.probing = false }
    let sid = "probe-session-0001"
    let nonce = #"{"nonce":"abcd1234","target":"/tmp/some-repo","why":"push targets main","ts":1}"#
    fm.createFile(atPath: dir + "/.push-nonce-" + sid, contents: Data(nonce.utf8))
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let ask = #"{"nonce":"ef567890","key":"slack.post","what":"posting to Slack","ts":1}"#
    try? fm.createDirectory(atPath: dir + "/.policy-ask", withIntermediateDirectories: true)
    fm.createFile(atPath: dir + "/.policy-ask/" + sid + "--slack.post.nonce", contents: Data(ask.utf8))
    let all = NeedsYou.items()
    check("the held ask is listed", all.contains { $0.kind == .ask })
    check("every item carries details", all.allSatisfy { !$0.details.isEmpty })
    if let askItem = all.first(where: { $0.kind == .ask }) {
        check("approving the ask reports success", NeedsYou.approve(askItem) == nil)
        check("the ask's approval file the guard reads exists",
              fm.fileExists(atPath: dir + "/.policy-ask/" + sid + "--slack.post.approved"))
    }
    let items = all.filter { $0.kind == .push }
    check("the held push is listed", items.count == 1)
    check("an ended session gets no Approve button",
          NeedsYou.groups(items) {}.last?.rows.dropFirst().first?.buttons.contains { $0.label == "Approve" } == false)
    if let item = items.first {
        check("approve reports success", NeedsYou.approve(item) == nil)
        check("the approval file the gate reads exists", fm.fileExists(atPath: dir + "/.push-approved-" + sid))
        check("the held push itself is left for the gate to clear", fm.fileExists(atPath: dir + "/.push-nonce-" + sid))
        let after = NeedsYou.items()
        check("an ended session holding a push and its approval shows one row",
              after.filter { $0.sessionID == sid && $0.kind != .ask }.count == 1,
              after.filter { $0.sessionID == sid }.map(\.title).joined(separator: ", "))
        check("every item is read from the probe folder, never ~/.claude",
              after.allSatisfy { $0.files.allSatisfy { $0.hasPrefix(dir) } })
        // Cancel after approve must leave neither file, as typing "cancel push" does.
        check("cancel reports success", NeedsYou.cancel(item) == nil)
        check("cancel removes the held push", !fm.fileExists(atPath: dir + "/.push-nonce-" + sid))
        check("cancel removes its approval, so a retried push is held again",
              !fm.fileExists(atPath: dir + "/.push-approved-" + sid))
    }
    if let askItem = NeedsYou.items().first(where: { $0.kind == .ask }) {
        check("cancel on an ask reports success", NeedsYou.cancel(askItem) == nil)
        check("cancel on an ask removes it and its approval, as typing deny does",
              !fm.fileExists(atPath: dir + "/.policy-ask/" + sid + "--slack.post.nonce")
              && !fm.fileExists(atPath: dir + "/.policy-ask/" + sid + "--slack.post.approved"))
    }
    check("nothing is left waiting after both cancels", NeedsYou.items().isEmpty)

    // The Approvals tab's sections, and Clear all carrying on past a failure.
    let live = NeedItem(id: "live", kind: .push, title: "Push a", sessionID: "s1", sessionDir: "/tmp",
                        since: nil, approveLine: "approve push x", files: [])
    let stuckDir = dir + "/locked"
    try? fm.createDirectory(atPath: stuckDir, withIntermediateDirectories: true)
    fm.createFile(atPath: stuckDir + "/held", contents: Data())
    fm.createFile(atPath: dir + "/free", contents: Data())
    _ = chmod(stuckDir, 0o555)
    defer { _ = chmod(stuckDir, 0o755) }
    let stuck = NeedItem(id: "stuck", kind: .ask, title: "Stuck ask", sessionID: "gone1", sessionDir: nil,
                         since: nil, approveLine: nil, files: [stuckDir + "/held"])
    let free = NeedItem(id: "free", kind: .ask, title: "Free ask", sessionID: "gone2", sessionDir: nil,
                        since: nil, approveLine: nil, files: [dir + "/free"])
    let groups = NeedsYou.groups([live, stuck, free]) {}
    check("the tab has a Pushes and a Left by ended sessions section",
          groups.map(\.title) == ["Pushes", "Left by ended sessions"], groups.map(\.title).joined(separator: ","))
    if let clear = groups.last?.rows.first?.buttons.first, case .run(let clearAll) = clear.kind {
        let err = clearAll() ?? ""
        check("Clear all names the one it could not clear", err.hasPrefix("1 of 2 not cleared") && err.contains("Stuck ask"), err)
        check("Clear all still clears the rest", !fm.fileExists(atPath: dir + "/free"))
    } else {
        check("the ended-sessions section starts with a Clear all row", false)
    }
    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

/// "Tue 29 Sep, 7:45 AM", for the details below a row.
func fullDate(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"
    return f.string(from: d)
}
