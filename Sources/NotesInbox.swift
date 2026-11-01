// NotesInbox.swift
// What arrived from somewhere else and has not been looked at: a new note or save that came in through a
// merge and was not written on this Mac. It is derived from what the merge brought in, so no key is added to
// any note file, and this Mac's own seen state lives in the state folder. An item leaves by keep, done or later.
// An agent's note goes to the agents lane, not the owner's list, and nothing here wakes an agent.

import Foundation
import UserNotifications

final class NotesInbox: ObservableObject {
    static let shared = NotesInbox()

    struct Item: Codable, Identifiable, Equatable {
        /// The file's place under the notes folder without `.md`: `20261101-120000-ab12`, or `.saved/8849d9f8cb0c`.
        var id: String
        var kind: String          // "note" or "save"
        var title: String
        var at: Date
        /// Hidden until this time, when it comes back.
        var later: Date?
        var agent: String?
        /// Who brought it: the commit author that added it, as git names them.
        var from: String?
        var isSave: Bool { kind == "save" }
    }

    /// What the views read; always assigned on the main thread.
    @Published private(set) var items: [Item] = []
    /// The truth, guarded by a lock because a sync round adds to it off the main thread.
    private var backing: [Item] = []
    private let lock = NSLock()
    private func change<T>(_ body: (inout [Item]) -> T) -> T {
        lock.lock()
        let out = body(&backing)
        let snap = backing
        lock.unlock()
        write(snap)
        if Thread.isMainThread { items = snap } else { DispatchQueue.main.async { self.items = snap } }
        return out
    }

    /// Where this Mac keeps its inbox: beside the other state, never in the notes folder.
    static var path: String { AppPaths.stateDir + "/notes-inbox.json" }
    /// More arrivals than this in one merge are a first sync or a bulk import, not things to look at one by one.
    static let bulkLimit = 30
    /// How an arrival is announced. The app posts a macOS notification; a probe replaces this to count them.
    static var deliver: (_ title: String, _ body: String, _ id: String) -> Void = NotesInbox.postNotification

    init() { load() }

    // ── What the owner sees ─────────────────────────────────────────────────

    /// The owner's own list: not an agent's, and not put off until later.
    func waiting(now: Date = Date()) -> [Item] { items.filter { $0.agent == nil && ($0.later ?? .distantPast) <= now }.sorted { $0.at > $1.at } }
    /// The agents lane: what agents wrote, kept apart so it never reads as the owner's own.
    func lane(now: Date = Date()) -> [Item] { items.filter { $0.agent != nil && ($0.later ?? .distantPast) <= now }.sorted { $0.at > $1.at } }

    /// Notes an agent wrote that have not been kept: they stay out of the owner's list until the owner keeps one.
    var agentLaneIDs: Set<String> { Set(items.filter { $0.agent != nil && !$0.isSave }.map(\.id)) }

    // ── Taking a merge's arrivals in ────────────────────────────────────────

    /// The files a merge added, by id, from the names git reports relative to the notes folder
    /// (`x.md` and `.saved/y.md`; a subfolder's note or an attachment is not an arrival).
    static func arrivalIDs(fromNames names: [String]) -> [String] {
        names.compactMap { n -> String? in
            guard n.hasSuffix(".md") else { return nil }
            let id = String(n.dropLast(3))
            if id.hasPrefix(".saved/") { return id.dropFirst(7).contains("/") ? nil : id }
            return id.contains("/") || id.hasPrefix(".") ? nil : id
        }
    }

    /// Adds what a merge brought in. `read` gives a file's text; `author` who added it. Returns the new items.
    @discardableResult
    func ingest(ids: [String], dir: String, author: (String) -> String? = { _ in nil }, now: Date = Date()) -> [Item] {
        guard !ids.isEmpty else { return [] }
        guard ids.count <= Self.bulkLimit else {
            dlog("notes inbox: \(ids.count) files arrived at once, so none were listed one by one")
            return []
        }
        lock.lock(); let known = Set(backing.map(\.id)); lock.unlock()
        var added: [Item] = []
        for id in ids where !known.contains(id) {
            guard let text = try? String(contentsOfFile: dir + "/" + id + ".md", encoding: .utf8) else { continue }
            let r = NoteSpec.read(text, name: id.hasPrefix(".saved/") ? String(id.dropFirst(7)) : id)
            let title = r.title.isEmpty ? (r.url ?? id) : r.title
            added.append(Item(id: id, kind: id.hasPrefix(".saved/") ? "save" : "note", title: title, at: now, later: nil,
                              agent: r.agent, from: author(id)))
        }
        guard !added.isEmpty else { return [] }
        change { $0 += added }
        // an agent's note is told apart quietly; the owner is told about their own
        let mine = added.filter { $0.agent == nil }
        if !mine.isEmpty {
            let first = mine[0]
            let kind = first.isSave ? "save" : "note"
            let title = mine.count == 1 ? "New \(kind) from \(first.from ?? "another device")" : "\(mine.count) new notes and saves"
            let body = mine.count == 1 ? first.title : mine.prefix(3).map(\.title).joined(separator: ", ")
            Self.deliver(title, body, first.id)
        }
        return added
    }

    // ── Leaving the inbox ───────────────────────────────────────────────────

    /// Keep: it stays where it is, as a note or a save, and leaves the inbox.
    func keep(_ id: String) { drop(id) }

    /// Done: it leaves the inbox and is put away. A note expires now, so it shows under Expired and is never deleted;
    /// a save is removed, and its history stays in git.
    func done(_ id: String, notes: NotesStore = .shared, saved: SavedStore = .shared) {
        if id.hasPrefix(".saved/") { saved.remove(key: String(id.dropFirst(7))) }
        else if var n = notes.notes.first(where: { $0.id == id }), n.expires == nil { n.expires = Date(); notes.update(n) }
        drop(id)
    }

    /// Later: hidden until `until`, then back in the list.
    func later(_ id: String, until: Date) {
        change { list in if let i = list.firstIndex(where: { $0.id == id }) { list[i].later = until } }
    }

    private func drop(_ id: String) {
        change { $0.removeAll { $0.id == id } }
    }

    /// Items whose file is gone (deleted here or on another device) leave on their own.
    func prune(dir: String) {
        change { $0.removeAll { !FileManager.default.fileExists(atPath: dir + "/" + $0.id + ".md") } }
    }

    // ── Storage ─────────────────────────────────────────────────────────────

    private func load() {
        guard let d = FileManager.default.contents(atPath: Self.path) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let list = (try? dec.decode([Item].self, from: d)) ?? []
        lock.lock(); backing = list; lock.unlock()
        items = list
    }

    /// Reads the file again, for a probe that points the state folder elsewhere between runs.
    func reload() { lock.lock(); backing = []; lock.unlock(); items = []; load() }

    private func write(_ list: [Item]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(list) else { return }
        try? FileManager.default.createDirectory(atPath: AppPaths.stateDir, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
    }

    // ── The notification ────────────────────────────────────────────────────

    static func postNotification(_ title: String, _ body: String, _ id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { dlog("notifications are off for Switchboard; the inbox shows the arrival in the app only"); return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: "inbox-" + id, content: c, trigger: nil)) { err in
                if let err { dwarn("inbox notification not added: \(fmtErr(err))") }
            }
        }
    }
}
