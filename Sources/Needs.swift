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
    /// Everything known about it, for the details below the row.
    var details: [(String, String)] = []
}

enum NeedsYou {
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

        // Approvals already typed whose session ended before using them.
        for a in PushApprovals.armed(liveSessionIDs: Set(live.keys)) where !a.sessionIsLive {
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
        _ = Services.shell("/bin/bash", [root + "/scripts/hooks/warn-log.sh", "--hook", item.kind == .push ? "push-gate" : "policy-ask",
                                         "--action", "panel-approved", "--heeded", "yes"], timeout: 5)
        nudge(item)
        return nil
    }

    /// Tell the waiting session it is approved, so it retries without waiting
    /// for the owner's next message. Sent as a request because the ipc inbox
    /// monitor wakes an idle session only for requests, queries and responses;
    /// an inform would sit until the next turn. Best effort: the gate trusts the
    /// file, never this message, and the session's next prompt also says so.
    private static func nudge(_ item: NeedItem) {
        let peers = Services.shell("/bin/zsh", ["-lc", "claude-ipc peers --by-session"], timeout: 8)
        guard let d = peers.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["peers"] as? [[String: Any]],
              let alias = (list.first { ($0["sessionId"] as? String) == item.sessionID }?["aliases"] as? [String])?.first
        else { dlog("approve: no ipc mailbox for \(item.sessionID); it will see the approval on its next prompt"); return }
        _ = Services.shell("/bin/zsh", ["-lc", "claude-ipc register switchboard-panel --service >/dev/null 2>&1"], timeout: 8)
        let msg = item.kind == .push
            ? "[push-gate] the owner approved \(item.title.lowercased()) from the Switchboard panel; the single-use approval is written. Re-run the same git push now."
            : "[policy-ask] the owner approved \(item.title.lowercased()) from the Switchboard panel; the single-use approval is written. Run the same call again now; it covers that one call."
        _ = Services.shell("/bin/zsh", ["-lc", "claude-ipc send --to \(shellQuote(alias)) --from switchboard-panel --kind request --reply-by none \(shellQuote(msg))"], timeout: 10)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Cancel: what typing "cancel push" or "deny <key>" does. Returns what
    /// went wrong, or nil.
    static func cancel(_ item: NeedItem) -> String? {
        for f in item.files where FileManager.default.fileExists(atPath: f) {
            do { try FileManager.default.removeItem(atPath: f) } catch { return error.localizedDescription }
        }
        return nil
    }

    /// The strip's rows: each live item on its own, then everything whose
    /// session has ended folded into one row with Clear all.
    static func rows(_ items: [NeedItem], refresh: @escaping () -> Void) -> [SystemRow] {
        let live = items.filter { $0.sessionDir != nil }
        let dead = items.filter { $0.sessionDir == nil }
        var out = itemRows(live, refresh: refresh)
        if !dead.isEmpty {
            var r = SystemRow(label: "\(dead.count) left by ended sessions", state: .count(dead.count, menuYellow),
                              note: "nothing will retry them; clear to tidy up",
                              tip: "Pushes and asks whose session is gone, and approvals never used. Click to list them.")
            r.key = "needs-dead"
            r.children = itemRows(dead, refresh: refresh)
            r.buttons = [RowButton(label: "Cancel", kind: .run({
                let err = dead.lazy.compactMap(cancel).first
                DispatchQueue.main.async(execute: refresh)
                return err
            }), help: "Clear all of them", doing: "clear them")]
            out.append(r)
        }
        return out
    }

    private static func itemRows(_ items: [NeedItem], refresh: @escaping () -> Void) -> [SystemRow] {
        items.map { item in
            let where_ = item.sessionDir.map { "session in " + (($0 as NSString).lastPathComponent) } ?? "session ended"
            let when = item.since.map { " · " + age($0) } ?? ""
            let note: String
            switch item.kind {
            case .push, .ask:
                note = item.approved ? "approved · runs when that session next takes a turn" : where_ + when
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

/// The strip above the tabs: a yellow-edged card, only while something waits.
struct NeedsStrip: View {
    @ObservedObject var store: PolicyStore

    var body: some View {
        if !store.needs.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 9.5, weight: .semibold))
                    Text("NEEDS YOU").font(PT.section).tracking(0.7)
                    Text("\(store.needs.count)").font(PT.section).foregroundStyle(.secondary)
                }
                .foregroundStyle(Color(nsColor: menuYellow))
                .padding(.leading, 4)
                Card {
                    ForEach(Array(store.needs.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().padding(.leading, PT.rowH) }
                        SystemRowView(row: row, store: store)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: menuYellow).opacity(0.5)))
            }
            .padding(.horizontal, PT.gap).padding(.top, PT.gap - 4)
        }
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
    defer { NeedsYou.rootOverride = nil }
    let sid = "probe-session-0001"
    let nonce = #"{"nonce":"abcd1234","target":"/tmp/some-repo","why":"push targets main","ts":1}"#
    fm.createFile(atPath: dir + "/.push-nonce-" + sid, contents: Data(nonce.utf8))
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "ok  " : "FAIL") \(name)") }
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
          NeedsYou.rows(items) {}.first?.children.first?.buttons.contains { $0.label == "Approve" } == false)
    if let item = items.first {
        check("approve reports success", NeedsYou.approve(item) == nil)
        check("the approval file the gate reads exists", fm.fileExists(atPath: dir + "/.push-approved-" + sid))
        check("the held push itself is left for the gate to clear", fm.fileExists(atPath: dir + "/.push-nonce-" + sid))
    }
    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

/// "Tue 29 Sep, 7:45 AM", for the details below a row.
func fullDate(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"
    return f.string(from: d)
}
