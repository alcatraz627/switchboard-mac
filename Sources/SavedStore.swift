// SavedStore.swift
// Saves: pointers to something elsewhere (a page, a file, a folder), one file each in `.saved/` under the notes
// folder, in the same format as a note. The file name is the first 12 hex characters of the SHA-1 of the
// normalised link, so two devices saving one link make one file. Tag colours come from `.meta/tags.json`.

import AppKit
import SwiftUI

final class SavedStore: ObservableObject {
    static let shared = SavedStore()

    @Published private(set) var items: [Note] = []
    @Published private(set) var loaded = false
    @Published private(set) var notice: String?
    @Published var error: String?

    static var dir: String { NotesStore.dir + "/.saved" }
    func path(_ id: String) -> String { Self.dir + "/" + id + ".md" }

    // ── Reading ─────────────────────────────────────────────────────────────

    func load() { apply(Self.readAll()) }
    func loadInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.readAll()
            DispatchQueue.main.async { self.apply(r) }
        }
    }
    private func apply(_ r: [Note]) { items = r; loaded = true }

    /// Every save, newest first (a save's own `created`, else its file's time).
    static func readAll() -> [Note] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.compactMap { f -> Note? in
            guard let text = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { return nil }
            return NotesStore.parse(id: String(f.dropLast(3)), text)
        }.sorted { ($0.created, $1.id) > ($1.created, $0.id) }
    }

    // ── Changing ────────────────────────────────────────────────────────────

    /// Saves a link, a folder or a file. A link already saved is kept as it is and returned. At least one of
    /// title, text and link is needed. A Mac file or folder link is marked as opening on the Mac only.
    @discardableResult
    func add(url rawURL: String, title: String = "", tags: [String] = []) -> Note? {
        let url = NoteSpec.normalisedURL(rawURL)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty || !t.isEmpty else { return nil }
        let id = url.isEmpty ? NotesStore.shared.newSaveID() : NoteSpec.saveKey(url)
        // the folder is read first when this store has not read it yet, so a link already saved is never written over
        if !loaded { load() }
        if let same = items.first(where: { $0.id == id }) { say("Already saved"); return same }
        if let text = try? String(contentsOfFile: path(id), encoding: .utf8), let on = NotesStore.parse(id: id, text) { say("Already saved"); return on }
        var n = Note(id: id, title: t.isEmpty ? Self.guessTitle(url) : t, body: "", tags: tags, created: NotesStore.now())
        n.url = url.isEmpty ? nil : url
        if url.lowercased().hasPrefix("file://") { n.device = "mac" }
        guard write(n) else { return nil }
        items.insert(n, at: 0)
        return n
    }

    /// A title for a save the owner gave none: a file's name, or the site and path.
    static func guessTitle(_ url: String) -> String {
        guard let u = URL(string: url) else { return url }
        if u.isFileURL { return u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent }
        let path = u.path == "/" ? "" : u.path
        return (u.host ?? url) + path
    }

    /// Changes a few keys of a save's file as it is on disk now, under the lock; the in-memory copy then follows the file.
    @discardableResult
    func patch(_ id: String, commit: Bool = true, _ change: (inout NoteSpec.Record) -> Void) -> Bool {
        guard let text = NotesStore.patchFile(at: path(id), name: id, change), let n = NotesStore.parse(id: id, text) else { return false }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = n } else { items.insert(n, at: 0) }
        if commit { NotesSync.shared.commit("save") }
        return true
    }

    /// Tags the save carries, from the file as it is now. `change` gets the tags on disk and returns the new ones.
    func setTags(_ id: String, _ tags: [String]) {
        patch(id) { $0.tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    func rename(_ id: String, to title: String) {
        patch(id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Removes the save. The file leaves the folder and the next sync commit; its history stays in git.
    func remove(key: String) {
        let p = path(key)
        let fm = FileManager.default
        let trash = NotesStore.trashDir + "/.saved"
        do {
            // set aside in `.trash/.saved` (this Mac's undo, never committed), so Recently deleted can bring it back
            try NotesSync.shared.locked {
                try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
                var to = trash + "/" + key + ".md"
                if fm.fileExists(atPath: to) { to = trash + "/" + key + "-" + String(Int(Date().timeIntervalSince1970)) + ".md" }
                try fm.moveItem(atPath: p, toPath: to)
            }
            NotesSync.shared.commit("remove save")
        } catch { self.error = "the save could not be removed: \(error.localizedDescription)"; return }
        items.removeAll { $0.id == key }
        NotesStore.shared.loadTrash()
    }

    private func write(_ n: Note) -> Bool {
        if let gone = NotesStore.missingFolder { error = gone; return false }
        do {
            try FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
            let text = NotesStore.render(n)
            try NotesSync.shared.locked { try text.write(toFile: path(n.id), atomically: true, encoding: .utf8) }
            error = nil
            NotesSync.shared.commit("save")
            return true
        } catch {
            self.error = "the save could not be written: \(error.localizedDescription)"
            return false
        }
    }

    func say(_ s: String) {
        notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.notice == s { self?.notice = nil } }
    }

    // ── The one-time move of older pins ─────────────────────────────────────

    /// Set once the move has run on this Mac; the move runs only while it is absent.
    static let migratedKey = "switchboard.notes.savedMigrated"

    /// Older notes at the top level with a `url:` line, or the tag `pin`, become saves: moved into `.saved/` in one
    /// commit, named by the link's hash (their own id when they have no link), the `pin` tag dropped, and a Mac file
    /// link marked as opening on the Mac. A note with a reminder stays a note, since only notes ring. Returns how
    /// many moved. Runs once per Mac, then sets the migration key.
    @discardableResult
    func migrateOldPinsIfNeeded() -> Int {
        let d = NotesStore.defaults
        guard d.object(forKey: Self.migratedKey) == nil, NotesStore.missingFolder == nil else { return 0 }
        let fm = FileManager.default
        let top = NotesStore.dir
        guard (try? fm.contentsOfDirectory(atPath: top)) != nil else { return 0 }
        var moved = 0
        // The files are read inside the lock, so a note edited a moment before is moved as it is then, never as it was.
        NotesSync.shared.commitAlone({ moved == 0 ? "save" : "saved: move \(moved) older pin\(moved == 1 ? "" : "s")" }) {
            guard let names = try? fm.contentsOfDirectory(atPath: top) else { return }
            var moves: [(from: String, to: String, text: String)] = []
            var taken = Set<String>(((try? fm.contentsOfDirectory(atPath: Self.dir)) ?? []).map { String($0.dropLast(3)) })
            for f in names.sorted() where f.hasSuffix(".md") && !f.hasPrefix(".") {
                let id = String(f.dropLast(3))
                guard let text = try? String(contentsOfFile: top + "/" + f, encoding: .utf8), !NotesSync.conflicted(text),
                      var n = NotesStore.parse(id: id, text) else { continue }
                let hasLink = !(n.url ?? "").isEmpty
                let pinTag = n.tags.contains { $0.lowercased() == "pin" }
                guard hasLink || pinTag, n.remindAt == nil else { continue }
                n.tags.removeAll { $0.lowercased() == "pin" }
                if let u = n.url, u.lowercased().hasPrefix("file://"), n.device == nil { n.device = "mac" }
                var target = hasLink ? NoteSpec.saveKey(n.url ?? "") : id
                // a second note for a link already saved keeps its own id, so no words are lost
                if taken.contains(target) { target = id }
                if taken.contains(target) { continue }
                taken.insert(target)
                n = Note(id: target, title: n.title, body: n.body, tags: n.tags, created: n.created, expires: n.expires, remindAt: n.remindAt,
                         remindRepeat: n.remindRepeat, remindOn: n.remindOn, reminderID: n.reminderID, pinned: n.pinned, color: n.color,
                         agent: n.agent, source: n.source, url: n.url, remindPersist: n.remindPersist, device: n.device, pos: nil, extra: n.extra)
                moves.append((f, target, NotesStore.render(n)))
            }
            guard !moves.isEmpty else { return }
            try? fm.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
            for m in moves {
                guard (try? m.text.write(toFile: Self.dir + "/" + m.to + ".md", atomically: true, encoding: .utf8)) != nil else { continue }
                try? fm.removeItem(atPath: top + "/" + m.from)
                moved += 1
            }
        }
        d.set(ISO8601DateFormatter().string(from: Date()), forKey: Self.migratedKey)
        dlog("saved: \(moved) older pins moved into .saved")
        return moved
    }

    /// The same move, off the main thread: it waits for the sync queue, which can take as long as a network round.
    func migrateOldPinsInBackground() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let n = migrateOldPinsIfNeeded()
            if n > 0 { DispatchQueue.main.async { self.load(); NotesStore.shared.loadInBackground() } }
        }
    }

    // ── Opening ─────────────────────────────────────────────────────────────

    enum Opening: Equatable {
        case open(URL)
        /// Said in words, and nothing opens.
        case cannot(String)
    }

    /// What opening a save does here. A `file://` link opens only on the device it names, and only when it is still there.
    static func opening(_ n: Note, onThisMac: Bool = true) -> Opening {
        guard let raw = n.url ?? n.body.components(separatedBy: "\n").first(where: { !$0.isEmpty }), let u = URL(string: raw) else {
            return .cannot("This save has no link to open.")
        }
        guard u.isFileURL else { return .open(u) }
        if let d = n.device, d != "mac" { return .cannot("This file is on the \(d), so it opens there.") }
        guard FileManager.default.fileExists(atPath: u.path) else {
            return .cannot("That file is not on this Mac any more: \(abbreviateHome(u.path)).")
        }
        return .open(u)
    }

    func open(_ n: Note) {
        switch Self.opening(n) {
        case .open(let u): NSWorkspace.shared.open(u)
        case .cannot(let why): say(why)
        }
    }

    func copyLink(_ n: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.url ?? n.title, forType: .string)
        say("Copied the link")
    }
}

// ── Tag colours ─────────────────────────────────────────────────────────────

/// Tag colours shared with every device: `.meta/tags.json`, `{"name": "#hex or colour name"}`.
enum TagColors {
    static var path: String { NotesStore.dir + "/.meta/tags.json" }

    private static var cache: (path: String, mtime: Date?, map: [String: String]) = ("", nil, [:])

    /// The tag colours, re-read only when the file's time changes, since rows ask on every redraw.
    static func read() -> [String: String] {
        let p = path
        let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        if cache.path == p, cache.mtime == m, m != nil { return cache.map }
        guard let d = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { cache = (p, m, [:]); return [:] }
        cache = (p, m, o)
        return o
    }

    /// The colour a tag wears, or nil for none.
    static func forTag(_ tag: String) -> Color? { read()[tag].flatMap { color($0) } }

    /// The colour a value names: one of the eight names, or a hex like `#3b82f6`; nil when it is neither.
    static func color(_ value: String) -> Color? {
        if NoteSpec.colors.contains(value) { return NotePalette.shared.color(value) }
        var h = value.hasPrefix("#") ? String(value.dropFirst()) : ""
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// Writes one tag's colour, or clears it with nil, keeping every other entry (and the file's other devices' entries).
    static func set(_ tag: String, to value: String?) {
        var all = read()
        if let value, !value.isEmpty { all[tag] = value } else { all[tag] = nil }
        guard let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: NotesStore.dir + "/.meta", withIntermediateDirectories: true)
        try? NotesSync.shared.locked { try (String(decoding: d, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        NotesSync.shared.commit("tag colours")
    }
}
