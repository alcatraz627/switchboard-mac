// Notes.swift
// Short notes the owner keeps at hand: one markdown file each, so a note's
// path can be handed to an agent. A note can expire (it dims and sinks to a
// collapsed Expired section; nothing is deleted) and can carry a reminder in
// macOS Reminders, once or on a repeat. The tab's view is in NotesView.swift.

import AppKit
import EventKit
import Foundation

/// Saves, reads back, expires, reorders and deletes notes in the state folder
/// the caller points SWITCHBOARD_STATE at; never touches Reminders.
func probeNotes() -> String {
    NotesStore.remindersOff = true
    let s = NotesStore()
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let a = s.add("Deploy: check \"prod\" first\nThe body line\nsecond line")
    check("a note is saved as a file", a.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    check("Enter on the same text does not save it twice", s.add("Deploy: check \"prod\" first\nThe body line\nsecond line")?.id == a?.id && s.notes.count == 1)
    let b = s.add("Second note")
    var edited = b!
    edited.tags = ["ops", "later"]
    edited.expires = Date().addingTimeInterval(-60)
    s.update(edited)
    s.load()
    let back = s.notes.first { $0.id == a?.id }
    check("a colon and quotes in the title survive the file", back?.title == "Deploy: check \"prod\" first", back?.title ?? "nil")
    check("the body survives the file", back?.body == "The body line\nsecond line", back?.body ?? "nil")
    let e = s.notes.first { $0.id == b?.id }
    check("tags survive the file", e?.tags == ["ops", "later"], e?.tags.joined(separator: ",") ?? "nil")
    check("a past expiry moves the note to Expired", s.expired.map(\.id) == [b!.id] && s.live.map(\.id) == [a!.id])
    let c = s.add("Third")!
    // New notes go on top, so the order is c, b, a; drag a onto c's place.
    s.move(a!.id, to: c.id)
    s.saveOrder()
    s.load()
    check("a dragged order is kept across a reload", s.notes.map(\.id) == [a!.id, c.id, b!.id], s.notes.map(\.title).joined(separator: ","))
    s.delete(c)
    check("delete removes the file", !FileManager.default.fileExists(atPath: c.path) && !s.notes.contains { $0.id == c.id })
    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

struct Note: Identifiable, Equatable {
    enum Repeat: String, CaseIterable { case never, daily, weekly, monthly }

    let id: String
    var title: String
    var body: String
    var tags: [String]
    var created: Date
    var expires: Date?
    var remindAt: Date?
    var remindRepeat: Repeat = .never
    /// The Reminders item this note owns, so it can be changed or removed.
    var reminderID: String?

    var expired: Bool { expires.map { $0 <= Date() } ?? false }
    var path: String { NotesStore.dir + "/" + id + ".md" }
    /// Title and body as one text, the way Copy content hands it over.
    var content: String { body.isEmpty ? title : title + "\n\n" + body }
}

final class NotesStore: ObservableObject {
    /// The one store the tab and the hover preview share.
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var error: String?

    static var dir: String {
        let d = AppPaths.stateDir + "/notes"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private static var orderPath: String { dir + "/order.json" }

    // ── Reading and writing the files ───────────────────────────────────────

    func load() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: Self.dir)) ?? []).filter { $0.hasSuffix(".md") }
        let read = files.compactMap { f -> Note? in
            guard let text = try? String(contentsOfFile: Self.dir + "/" + f, encoding: .utf8) else { return nil }
            return Self.parse(id: String(f.dropLast(3)), text)
        }
        let order = (fm.contents(atPath: Self.orderPath).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }) ?? []
        // Newest first where the saved order has no place for a note yet.
        notes = applyOrder(read.sorted { $0.created > $1.created }, order)
    }

    /// Live notes in the owner's order, then expired ones.
    var live: [Note] { notes.filter { !$0.expired } }
    var expired: [Note] { notes.filter(\.expired) }

    @discardableResult
    func add(_ text: String) -> Note? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lines = t.components(separatedBy: "\n")
        let title = lines[0].trimmingCharacters(in: .whitespaces)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Enter on a note already saved does not make a second copy.
        if let same = notes.first(where: { $0.title == title && $0.body == body }) { return same }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        var id = f.string(from: Date())
        while notes.contains(where: { $0.id == id }) { id += "x" }
        let n = Note(id: id, title: title, body: body, tags: [], created: Date())
        guard write(n) else { return nil }
        notes.insert(n, at: 0)
        saveOrder()
        return n
    }

    /// Save a changed note; its reminder follows the change.
    func update(_ n: Note) {
        var n = n
        syncReminder(&n)
        guard write(n) else { return }
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n }
    }

    func delete(_ n: Note) {
        var gone = n
        gone.remindAt = nil
        syncReminder(&gone)
        do { try FileManager.default.removeItem(atPath: n.path) } catch {
            self.error = "\(n.title) could not be removed: \(error.localizedDescription)"; return
        }
        notes.removeAll { $0.id == n.id }
        saveOrder()
    }

    func move(_ dragged: String, to target: String) {
        notes = applyOrder(notes, reordered(notes.map(\.id), moving: dragged, to: target))
    }

    func saveOrder() {
        guard let d = try? JSONSerialization.data(withJSONObject: notes.map(\.id)) else { return }
        try? d.write(to: URL(fileURLWithPath: Self.orderPath), options: .atomic)
    }

    private func write(_ n: Note) -> Bool {
        do {
            try Self.render(n).write(toFile: n.path, atomically: true, encoding: .utf8)
            error = nil
            return true
        } catch {
            self.error = "the note could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    // ── The file format: a small frontmatter block, then the body ───────────

    private static let iso = ISO8601DateFormatter()

    /// Strings are written JSON-quoted, so a colon or quote in a title survives.
    static func render(_ n: Note) -> String {
        func q(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        var lines = ["---", "title: " + q(n.title), "created: " + iso.string(from: n.created)]
        if !n.tags.isEmpty { lines.append("tags: " + q(n.tags.joined(separator: ", "))) }
        if let e = n.expires { lines.append("expires: " + iso.string(from: e)) }
        if let r = n.remindAt {
            lines.append("remind_at: " + iso.string(from: r))
            if n.remindRepeat != .never { lines.append("remind_repeat: " + n.remindRepeat.rawValue) }
        }
        if let id = n.reminderID { lines.append("reminder_id: " + q(id)) }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + n.body + (n.body.isEmpty ? "" : "\n")
    }

    static func parse(id: String, _ text: String) -> Note? {
        var fields: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].components(separatedBy: "\n") {
                guard let c = line.firstIndex(of: ":") else { continue }
                var v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\""), let d = try? JSONSerialization.jsonObject(with: Data("[\(v)]".utf8)) as? [String], let s = d.first { v = s }
                fields[String(line[..<c]).trimmingCharacters(in: .whitespaces)] = v
            }
            body = String(text[end.upperBound...])
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = fields["title"] ?? body.components(separatedBy: "\n").first ?? id
        return Note(id: id, title: title, body: fields["title"] == nil ? "" : body,
                    tags: (fields["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    created: fields["created"].flatMap(iso.date) ?? Date.distantPast,
                    expires: fields["expires"].flatMap(iso.date),
                    remindAt: fields["remind_at"].flatMap(iso.date),
                    remindRepeat: fields["remind_repeat"].flatMap(Note.Repeat.init) ?? .never,
                    reminderID: fields["reminder_id"])
    }

    // ── Reminders ───────────────────────────────────────────────────────────

    private let events = EKEventStore()
    /// Set by the headless probe so it never touches the real Reminders.
    static var remindersOff = false

    /// Make Reminders match the note: add, move or remove its one reminder.
    /// Access is asked the first time a reminder is set, never before.
    private func syncReminder(_ n: inout Note) {
        guard !Self.remindersOff else { return }
        let existing = n.reminderID.flatMap { events.calendarItem(withIdentifier: $0) as? EKReminder }
        guard let at = n.remindAt else {
            if let r = existing { try? events.remove(r, commit: true) }
            n.reminderID = nil
            return
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized, .writeOnly: break
        case .notDetermined:
            // Ask once, off the main thread; the note is saved now and the reminder follows the answer.
            let pending = n
            events.requestFullAccessToReminders { [weak self] granted, _ in
                DispatchQueue.main.async {
                    if granted { self?.update(pending) }
                    else { self?.error = "Reminders access was not given, so the reminder was not set." }
                }
            }
            return
        default:
            error = "Switchboard may not add reminders. Allow it in System Settings > Privacy & Security > Reminders."
            return
        }
        let r = existing ?? EKReminder(eventStore: events)
        r.title = n.title
        r.notes = (n.body.isEmpty ? "" : n.body + "\n\n") + n.path
        if r.calendar == nil { r.calendar = events.defaultCalendarForNewReminders() }
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        r.alarms?.forEach { r.removeAlarm($0) }
        r.addAlarm(EKAlarm(absoluteDate: at))
        r.recurrenceRules?.forEach { r.removeRecurrenceRule($0) }
        let freq: EKRecurrenceFrequency? = [.daily: .daily, .weekly: .weekly, .monthly: .monthly][n.remindRepeat]
        if let f = freq { r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: f, interval: 1, end: nil)) }
        do {
            try events.save(r, commit: true)
            n.reminderID = r.calendarItemIdentifier
        } catch {
            self.error = "the reminder could not be saved: \(error.localizedDescription)"
        }
    }
}
