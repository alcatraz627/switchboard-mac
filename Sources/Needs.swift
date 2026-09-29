// Needs.swift
// The "Needs you" strip: everything an agent is waiting on the owner for (a
// push to a protected branch, an action behind an "ask" policy), shown above
// the tabs only while something waits.
//
// The panel never approves. Approving stays a line the owner types into the
// session, because an approval must be something no agent can actuate, and a
// button in a GUI app can be pressed by anything that drives the GUI (see the
// push gate's header in ~/.claude/scripts/hooks/guard-git-push.sh). The strip
// copies that line, and offers Cancel, which is safe for anyone to press: it
// only ever denies.

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
}

enum NeedsYou {
    private static var root: String { SwitchboardPaths.gccRoot }

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
            out.append(NeedItem(id: path, kind: .push,
                                title: "Push \(repo.lastPathComponent)",
                                sessionID: sid, sessionDir: live[sid], since: since(o, path),
                                approveLine: "approve push \(nonce)",
                                files: [path, root + "/.push-approved-" + sid]))
        }

        let askDir = root + "/.policy-ask"
        for f in (try? fm.contentsOfDirectory(atPath: askDir)) ?? [] where f.hasSuffix(".nonce") {
            let path = askDir + "/" + f
            guard let o = json(path), let nonce = o["nonce"] as? String, let key = o["key"] as? String else { continue }
            // Named <session>--<key>.nonce by guard-policy.sh.
            let sid = f.components(separatedBy: "--").first ?? ""
            let base = String(path.dropLast(".nonce".count))
            let what = (o["what"] as? String) ?? key
            out.append(NeedItem(id: path, kind: .ask,
                                title: what.prefix(1).uppercased() + what.dropFirst(),
                                sessionID: sid, sessionDir: live[sid], since: since(o, path),
                                approveLine: "approve \(key) \(nonce)",
                                files: [path, base + ".approved"]))
        }

        // Approvals already typed whose session ended before using them.
        for a in PushApprovals.armed(liveSessionIDs: Set(live.keys)) where !a.sessionIsLive {
            out.append(NeedItem(id: root + "/" + a.file, kind: .armedApproval,
                                title: "Unused push approval", sessionID: a.sessionID, sessionDir: nil,
                                since: a.armedAt, approveLine: nil, files: [root + "/" + a.file]))
        }
        return out.sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
    }

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
            case .push, .ask: note = where_ + when
            case .armedApproval: note = "typed, never used; the session ended" + when
            }
            var r = SystemRow(label: item.title, state: item.sessionDir == nil ? .off : .on(menuYellow), note: note,
                              tip: item.approveLine.map { "To approve, paste into that session: \($0)" } ?? "")
            r.key = item.id
            r.showsBadge = false
            if let line = item.approveLine, item.sessionDir != nil {
                r.buttons.append(RowButton(label: "Copy", kind: .copy(line),
                                           help: "Copy \"\(line)\" to paste into that session. Only a line you type approves."))
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
