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
    var p = s.notes.first { $0.id == a?.id }!
    p.pinned = true
    s.update(p)
    s.load()
    check("a pin survives the file", s.notes.first { $0.id == a?.id }?.pinned == true)
    check("an unpinned note stays unpinned", s.notes.first { $0.id == b?.id }?.pinned == false)
    check("a past expiry moves the note to Expired", s.expired.map(\.id) == [b!.id] && s.live.map(\.id) == [a!.id])
    let c = s.add("Third")!
    // New notes go on top, so the order is c, b, a; drag a onto c's place.
    s.move(a!.id, to: c.id)
    s.saveOrder()
    s.load()
    check("a dragged order is kept across a reload", s.notes.map(\.id) == [a!.id, c.id, b!.id], s.notes.map(\.title).joined(separator: ","))
    s.delete(c)
    check("delete removes the file", !FileManager.default.fileExists(atPath: c.path) && !s.notes.contains { $0.id == c.id })

    // A folder chosen in Settings that has gone missing is reported, never quietly re-created empty.
    let savedFolder = UserDefaults.standard.string(forKey: NotesStore.folderKey)
    let gone = NSTemporaryDirectory() + "sb-notes-missing-\(getpid())"
    UserDefaults.standard.set(gone, forKey: NotesStore.folderKey)
    let lost = NotesStore()
    lost.load()
    check("a missing chosen folder is said to be missing and not created",
          lost.loaded && lost.notes.isEmpty && lost.error?.contains("is missing") == true && !FileManager.default.fileExists(atPath: gone),
          lost.error ?? "nil")
    check("saving into it fails with that sentence and still creates nothing",
          lost.add("lost note") == nil && lost.error?.contains("is missing") == true && !FileManager.default.fileExists(atPath: gone))
    if let b = savedFolder { UserDefaults.standard.set(b, forKey: NotesStore.folderKey) } else { UserDefaults.standard.removeObject(forKey: NotesStore.folderKey) }
    check("a store that has not read yet is not loaded", !NotesStore().loaded)

    // Reminders through a stand-in: the permission dialog stays up until answer() runs.
    NotesStore.remindersOff = false
    var status = EKAuthorizationStatus.notDetermined
    var answer: ((Bool) -> Void)?
    var saved: [Note] = []
    var saveFails = false
    s.reminders = ReminderBackend(status: { status }, requestAccess: { answer = $0 },
                                  save: { n in
                                      if saveFails { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "calendar is read-only"]) }
                                      saved.append(n); return "rem-\(saved.count)" },
                                  remove: { _ in nil })
    func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    var r = s.add("Call the bank")!
    r.remindAt = Date().addingTimeInterval(3600)
    s.update(r)
    r.body = "typed while the dialog was up"
    s.update(r)
    status = .fullAccess
    answer?(true); pump()
    let after = s.notes.first { $0.id == r.id }
    check("the first reminder is created once access is given", saved.count == 1, "\(saved.count) saved")
    check("it carries what was typed while the dialog was up", saved.first?.body == "typed while the dialog was up"
          && after?.body == "typed while the dialog was up", after?.body ?? "nil")
    check("the note records its reminder", after?.reminderID == "rem-1", after?.reminderID ?? "nil")
    status = .denied
    var d = s.add("Denied one")!
    d.remindAt = Date().addingTimeInterval(3600)
    s.update(d)
    check("no access says so instead of passing quietly", s.error?.contains("may not add reminders") == true, s.error ?? "nil")
    status = .fullAccess; saveFails = true
    var f = s.add("Failing save")!
    f.remindAt = Date().addingTimeInterval(3600)
    s.update(f)
    check("a failed save says why", s.error?.contains("read-only") == true, s.error ?? "nil")
    NotesStore.remindersOff = true

    // A folder of the owner's own, holding a markdown file written by hand.
    let ud = UserDefaults.standard
    let chosenBefore = ud.string(forKey: NotesStore.folderKey)
    let own = AppPaths.stateDir + "/own-notes"
    // The owner's own folder exists already; the store never creates a chosen one.
    try? FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
    ud.set(own, forKey: NotesStore.folderKey)
    try? "# Shopping\n\n- milk\n- eggs\n".write(toFile: NotesStore.dir + "/shopping.md", atomically: true, encoding: .utf8)
    s.load()
    var h = s.notes.first { $0.id == "shopping" }
    check("a hand-written file reads its heading as the title", h?.title == "Shopping", h?.title ?? "nil")
    check("and keeps its body", h?.body == "- milk\n- eggs", h?.body ?? "nil")
    h?.tags = ["errands"]
    if let h = h { s.update(h); s.saveOrder() }
    let onDisk = (try? String(contentsOfFile: own + "/shopping.md", encoding: .utf8)) ?? ""
    check("editing it keeps the body in the file", onDisk.contains("- milk\n- eggs"), onDisk)
    check("the saved order is not written into the owner's folder", !FileManager.default.fileExists(atPath: own + "/order.json"))
    ud.set(chosenBefore, forKey: NotesStore.folderKey)

    // Title and body, either one optional, never both empty; a colour tag survives the file.
    check("a note with only a body is saved", s.add(title: "", body: "just the text")?.heading == "just the text")
    check("a note with neither is refused", s.add(title: "  ", body: "\n") == nil)
    let tinted = s.add(title: "Tinted", body: "", color: "purple")!
    s.load()
    check("a colour tag survives the file", s.notes.first { $0.id == tinted.id }?.color == "purple")
    check("there are eight tag colours, the Reminders set with green and yellow",
          timerColors.map(\.0) == ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"])
    check("an old colour name lands on its new one", tagColorName("indigo") == "purple" && tagColorName("mint") == "green"
          && tagColorName("gray") == "blue" && tagColorName("green") == "green" && tagColorName("plaid") == nil)
    let nobody = InputRules.copyButtons(title: "Only title", body: "")
    let notitle = InputRules.copyButtons(title: "", body: "only body")
    check("a title-only note offers only the title copy", nobody.title && !nobody.body)
    check("a body-only note offers only the text copy", notitle.body && !notitle.title)

    // Enter in a title: the rest of the line goes to the top of the body.
    let mid = InputRules.splitTitle(before: "Buy ", after: "milk and eggs", body: "")
    check("Enter mid-title moves the rest into an empty body", mid == ("Buy", "milk and eggs"), "\(mid)")
    let onto = InputRules.splitTitle(before: "Buy ", after: "milk", body: "at the shop")
    check("into a body that has text, on its own line above it", onto == ("Buy", "milk\nat the shop"), "\(onto)")
    let end = InputRules.splitTitle(before: "Buy milk", after: "", body: "at the shop")
    check("Enter at the end of a title leaves the body as it was", end == ("Buy milk", "at the shop"), "\(end)")

    // Opening a tab: the new input takes the keyboard unless something is being edited.
    check("the new input is focused when nothing is being edited", InputRules.focusNewInput(editing: nil))
    check("an edit in progress keeps the keyboard", !InputRules.focusNewInput(editing: "20261001-120000"))
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
    /// Pinned notes are the ones the menu-bar quick page lists.
    var pinned = false
    /// A colour tag, one of the timer colours by name; nil for none.
    var color: String? = nil

    var expired: Bool { expires.map { $0 <= Date() } ?? false }
    var path: String { NotesStore.dir + "/" + id + ".md" }
    /// Title and body as one text, the way Copy content hands it over.
    var content: String { body.isEmpty ? title : title.isEmpty ? body : title + "\n\n" + body }
    /// What a list shows as the note's name: the title, or the body's first line when there is no title.
    var heading: String {
        title.isEmpty ? (body.components(separatedBy: "\n").first { !$0.isEmpty } ?? "") : title
    }
}

final class NotesStore: ObservableObject {
    /// The one store the tab and the hover preview share.
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var error: String?
    /// True once the folder has been read, so an empty list can say "No notes yet" and not "still reading".
    @Published private(set) var loaded = false

    /// Where notes are kept: the folder chosen in Settings, or the state folder's notes.
    static let folderKey = "switchboard.notesFolder"
    static var defaultDir: String { AppPaths.stateDir + "/notes" }
    static var dir: String {
        let chosen = UserDefaults.standard.string(forKey: folderKey)
        let d = (chosen?.isEmpty == false ? chosen! : defaultDir)
        // Rows read a note's path on every redraw: a stat, not a create, when it exists.
        // Only the default folder is ever created: a folder the owner chose that has gone
        // missing (an unplugged drive) must not be quietly replaced by an empty one.
        if d == defaultDir && !FileManager.default.fileExists(atPath: d) {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        return d
    }
    /// A sentence when the folder chosen in Settings is not there, else nil.
    static var missingFolder: String? {
        let d = dir
        guard d != defaultDir, !FileManager.default.fileExists(atPath: d) else { return nil }
        return "The notes folder \(abbreviateHome(d)) is missing. Is its drive connected? Pick another folder in Settings."
    }
    /// The saved order lives beside the default notes, but never inside a
    /// folder of the owner's own that was chosen in Settings.
    private static var orderPath: String {
        let d = dir
        guard d != defaultDir else { return d + "/order.json" }
        return AppPaths.stateDir + "/notes-order" + d.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    // ── Reading and writing the files ───────────────────────────────────────

    /// Reads the folder off the main thread, for the panel and at launch; a
    /// big chosen folder then never makes the panel stutter as it opens.
    func loadInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            let read = Self.readAll()
            DispatchQueue.main.async { self.apply(read) }
        }
    }

    func load() { apply(Self.readAll()) }

    /// Take a finished read; a problem with the folder shows as the tab's error line.
    private func apply(_ r: (notes: [Note], problem: String?)) {
        notes = r.notes
        loaded = true
        // A read problem clears itself when the next read is clean (a drive plugged back in).
        if let p = r.problem { readProblem = p; error = p }
        else if let old = readProblem { readProblem = nil; if error == old { error = nil } }
    }
    private var readProblem: String?
    private static let readProblemTag = "Notes could not be read: "

    private static func readAll() -> (notes: [Note], problem: String?) {
        if let gone = missingFolder { return ([], gone) }
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: Self.dir) } catch {
            return ([], readProblemTag + "the folder could not be listed (\(error.localizedDescription)).")
        }
        let files = names.filter { $0.hasSuffix(".md") }
        var skipped = 0
        let read = files.compactMap { f -> Note? in
            guard let text = try? String(contentsOfFile: Self.dir + "/" + f, encoding: .utf8) else { skipped += 1; return nil }
            return Self.parse(id: String(f.dropLast(3)), text)
        }
        let order = (fm.contents(atPath: Self.orderPath).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }) ?? []
        // Newest first where the saved order has no place for a note yet.
        let problem = skipped == 0 ? nil : readProblemTag + (skipped == 1 ? "1 file is not readable text." : "\(skipped) files are not readable text.")
        return (applyOrder(read.sorted { $0.created > $1.created }, order), problem)
    }

    /// Live notes in the owner's order, then expired ones.
    var live: [Note] { notes.filter { !$0.expired } }
    var expired: [Note] { notes.filter(\.expired) }

    @discardableResult
    func add(_ text: String) -> Note? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lines = t.components(separatedBy: "\n")
        return add(title: lines[0], body: lines.dropFirst().joined(separator: "\n"))
    }

    /// Saves a new note from a title and a body, either of which may be empty
    /// but not both; the same note twice is saved once.
    @discardableResult
    func add(title rawTitle: String, body rawBody: String, color: String? = nil) -> Note? {
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InputRules.canSave(title: title, body: body) else { return nil }
        // Enter on a note already saved does not make a second copy.
        if let same = notes.first(where: { $0.title == title && $0.body == body }) { return same }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        var id = f.string(from: Date())
        while notes.contains(where: { $0.id == id }) { id += "x" }
        var n = Note(id: id, title: title, body: body, tags: [], created: Date())
        n.color = color.flatMap(tagColorName)
        guard write(n) else { return nil }
        notes.insert(n, at: 0)
        saveOrder()
        return n
    }

    /// Save a changed note; its reminder follows only a change to when, how
    /// often or what it says, so typing in the body does not touch Reminders.
    func update(_ n: Note) {
        var n = n
        let old = notes.first { $0.id == n.id }
        var problem: String?
        if old?.remindAt != n.remindAt || old?.remindRepeat != n.remindRepeat || old?.title != n.title { problem = syncReminder(&n) }
        guard write(n) else { return }
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n }
        // After write, which clears the error line on success.
        if let p = problem { error = p }
    }

    func delete(_ n: Note) {
        var gone = n
        gone.remindAt = nil
        let reminderProblem = syncReminder(&gone)
        do { try FileManager.default.removeItem(atPath: n.path) } catch {
            self.error = "\(n.title) could not be removed: \(error.localizedDescription)"; return
        }
        notes.removeAll { $0.id == n.id }
        saveOrder()
        // The note is gone either way; a reminder left behind would fire for nothing.
        if let p = reminderProblem { self.error = "The note was deleted, but its reminder was not removed: \(p)" }
    }

    func move(_ dragged: String, to target: String) {
        notes = applyOrder(notes, reordered(notes.map(\.id), moving: dragged, to: target))
    }

    func saveOrder() {
        guard let d = try? JSONSerialization.data(withJSONObject: notes.map(\.id)) else { return }
        try? d.write(to: URL(fileURLWithPath: Self.orderPath), options: .atomic)
    }

    private func write(_ n: Note) -> Bool {
        if let gone = Self.missingFolder { error = gone; return false }
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
        if n.pinned { lines.append("pinned: true") }
        if let c = n.color { lines.append("color: " + c) }
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
        // A file written by hand has no title field: its first line is the
        // title (a markdown heading loses its #) and the rest stays the body.
        var title = fields["title"] ?? id
        if fields["title"] == nil, !body.isEmpty {
            let lines = body.components(separatedBy: "\n")
            title = lines[0].drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Note(id: id, title: title, body: body,
                    tags: (fields["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    created: fields["created"].flatMap(iso.date) ?? Date.distantPast,
                    expires: fields["expires"].flatMap(iso.date),
                    remindAt: fields["remind_at"].flatMap(iso.date),
                    remindRepeat: fields["remind_repeat"].flatMap(Note.Repeat.init) ?? .never,
                    reminderID: fields["reminder_id"],
                    pinned: fields["pinned"] == "true",
                    color: fields["color"].flatMap(tagColorName))
    }

    // ── Reminders ───────────────────────────────────────────────────────────

    private let events = EKEventStore()
    /// Set by the headless probe so it never touches the real Reminders.
    static var remindersOff = false
    /// macOS Reminders, or a stand-in the probe uses to play the permission dialog.
    lazy var reminders: ReminderBackend = .system(events)

    /// Make Reminders match the note: add, move or remove its one reminder.
    /// Access is asked the first time a reminder is set, never before.
    /// Returns what went wrong in plain words, or nil.
    private func syncReminder(_ n: inout Note) -> String? {
        guard !Self.remindersOff else { return nil }
        guard n.remindAt != nil else {
            guard let id = n.reminderID else { return nil }
            // Keep the id when removal fails, so the reminder can still be found later.
            if let why = reminders.remove(id) { return "the reminder could not be removed: \(why)" }
            n.reminderID = nil
            return nil
        }
        switch reminders.status() {
        case .fullAccess, .authorized, .writeOnly: break
        case .notDetermined:
            // The note is saved now and the reminder follows the answer, made
            // from the note as it is then: it may have been edited meanwhile.
            let id = n.id
            reminders.requestAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard granted else { self.error = "Reminders access was not given, so the reminder was not set."; return }
                    guard var now = self.notes.first(where: { $0.id == id }), now.remindAt != nil else { return }
                    let problem = self.syncReminder(&now)
                    guard self.write(now) else { return }
                    if let i = self.notes.firstIndex(where: { $0.id == id }) { self.notes[i] = now }
                    if let p = problem { self.error = p }
                }
            }
            return nil
        default:
            return "Switchboard may not add reminders. Allow it in System Settings > Privacy & Security > Reminders."
        }
        do {
            n.reminderID = try reminders.save(n)
            return nil
        } catch {
            return "the reminder could not be saved: \(error.localizedDescription)"
        }
    }
}

/// The three things notes need from Reminders.
struct ReminderBackend {
    var status: () -> EKAuthorizationStatus
    var requestAccess: (@escaping (Bool) -> Void) -> Void
    /// Adds or moves the note's one reminder; returns its identifier.
    var save: (Note) throws -> String
    /// Removes a reminder; returns why it could not, or nil (a reminder already gone counts as removed).
    var remove: (String) -> String?

    static func system(_ events: EKEventStore) -> ReminderBackend {
        func existing(_ id: String?) -> EKReminder? { id.flatMap { events.calendarItem(withIdentifier: $0) as? EKReminder } }
        return ReminderBackend(
            status: { EKEventStore.authorizationStatus(for: .reminder) },
            requestAccess: { done in events.requestFullAccessToReminders { granted, _ in done(granted) } },
            save: { n in
                let r = existing(n.reminderID) ?? EKReminder(eventStore: events)
                r.title = n.title
                r.notes = (n.body.isEmpty ? "" : n.body + "\n\n") + n.path
                if r.calendar == nil { r.calendar = events.defaultCalendarForNewReminders() }
                let at = n.remindAt ?? Date()
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                r.alarms?.forEach { r.removeAlarm($0) }
                r.addAlarm(EKAlarm(absoluteDate: at))
                r.recurrenceRules?.forEach { r.removeRecurrenceRule($0) }
                let freq: EKRecurrenceFrequency? = [.daily: .daily, .weekly: .weekly, .monthly: .monthly][n.remindRepeat]
                if let f = freq { r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: f, interval: 1, end: nil)) }
                try events.save(r, commit: true)
                return r.calendarItemIdentifier
            },
            remove: { id in
                guard let r = existing(id) else { return nil }
                do { try events.remove(r, commit: true); return nil } catch { return error.localizedDescription }
            })
    }
}
