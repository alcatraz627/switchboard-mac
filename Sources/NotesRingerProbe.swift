// NotesRingerProbe.swift
// Headless checks for ringing: which reminders ring on this Mac, that a time rings once, that a late one is missed,
// that the phone's are left alone, and that dismissing edits the file the way the spec says.

import Foundation

func probeReminders() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    NotesStore.remindersOff = true
    let s = NotesStore()
    let r = ReminderRinger()
    r.chimeAloud = false
    var shown: [String] = []
    r.announce = { shown.append($0.id) }
    let now = Date()
    func make(_ title: String, at: TimeInterval, repeating: Note.Repeat = .never, on: String? = nil, persist: Bool = false) -> Note {
        var n = s.add(title: title, body: "reminder probe")!
        n.remindAt = now.addingTimeInterval(at); n.remindRepeat = repeating; n.remindOn = on; n.remindPersist = persist
        s.update(n)
        return s.notes.first { $0.id == n.id }!
    }
    let fresh = make("fresh", at: -10)
    let persistLate = make("persistent and late", at: -3600, persist: true)
    let plainLate = make("late and not persistent", at: -3600)
    let phone = make("for the phone", at: -10, on: "phone")
    let future = make("later today", at: 3600)
    let daily = make("daily", at: -10, repeating: .daily)

    r.check(s.notes, now: now)
    check("a due reminder, a late one with or without persist, and a due repeating one all ring", r.ringing == [fresh.id, persistLate.id, plainLate.id, daily.id], "\(r.ringing)")
    check("each ring raised a notification and a chime", shown.count == 4 && r.chimes >= 4, "\(shown.count) / \(r.chimes)")
    check("a reminder an hour late still announces and rings, however late", r.ringing.contains(plainLate.id) && shown.contains(plainLate.id))
    check("a reminder for the phone is left alone: no ring, no error", !r.ringing.contains(phone.id) && !shown.contains(phone.id))
    check("a reminder in the future does not ring", !r.ringing.contains(future.id))
    r.check(s.notes, now: now.addingTimeInterval(5))
    check("one time rings once: a second look raises nothing new", shown.count == 4)
    r.check(s.notes, now: now.addingTimeInterval(4000))
    check("a ring that is not persistent ends, and the reminder then stays as missed", !r.ringing.contains(plainLate.id) && r.missed(plainLate, now: now.addingTimeInterval(4000)))
    check("a persistent one is still ringing", r.ringing.contains(persistLate.id))

    // S1: a repeating reminder nobody dismissed rings at its next time too
    let announcedBefore = shown.filter { $0 == daily.id }.count
    r.check(s.notes, now: now.addingTimeInterval(86_400 + 5))
    check("an undismissed daily reminder rings again the next day", shown.filter { $0 == daily.id }.count == announcedBefore + 1, "\(shown.filter { $0 == daily.id }.count)")
    r.check(s.notes, now: now.addingTimeInterval(86_400 + 60))
    check("and only once for that day", shown.filter { $0 == daily.id }.count == announcedBefore + 1)
    check("the latest time of a daily reminder is found by stepping", ReminderRinger.latest(onOrBefore: now.addingTimeInterval(3 * 86_400 + 5), from: now.addingTimeInterval(-10), every: .daily) == now.addingTimeInterval(3 * 86_400 - 10))

    // S2: the next launch rings what came due while the app was quit, and does not ring again what already rang
    let r1 = ReminderRinger(persist: true), r2 = ReminderRinger(persist: true)
    var first: [String] = [], second: [String] = []
    r1.chimeAloud = false; r2.chimeAloud = false
    r1.announce = { first.append($0.id) }; r2.announce = { second.append($0.id) }
    AppDefaults.store.removeObject(forKey: ReminderRinger.handledKey)
    let rl = ReminderRinger(persist: true); rl.chimeAloud = false; var lateSeen: [String] = []; rl.announce = { lateSeen.append($0.id) }
    rl.check([plainLate], now: now)
    check("a reminder that came due while the app was quit rings at the next launch, however late", lateSeen == [plainLate.id], "\(lateSeen)")
    let relaunched = ReminderRinger(persist: true); relaunched.chimeAloud = false; var again: [String] = []; relaunched.announce = { again.append($0.id) }
    relaunched.check([plainLate], now: now.addingTimeInterval(60))
    check("and a relaunch does not ring it a second time", again.isEmpty, "\(again)")
    _ = (r1, r2, first, second)
    AppDefaults.store.removeObject(forKey: ReminderRinger.handledKey)

    // S14: an answer to an old notification changes nothing when the reminder moved or is not due
    var moved1 = s.notes.first { $0.id == future.id }!
    r.dismiss(moved1.id, notes: s, now: now, expectedAt: moved1.remindAt)
    check("dismissing a reminder that is not due yet changes nothing", s.notes.first { $0.id == future.id }?.remindAt != nil
          && abs((s.notes.first { $0.id == future.id }?.remindAt ?? .distantPast).timeIntervalSince(moved1.remindAt ?? .distantFuture)) < 1)
    moved1 = s.notes.first { $0.id == persistLate.id }!
    r.dismiss(moved1.id, notes: s, now: now, expectedAt: now.addingTimeInterval(-5000))
    check("an answer about another time than the file now holds changes nothing", s.notes.first { $0.id == persistLate.id }?.remindAt != nil)

    r.dismiss(fresh.id, notes: s, now: now)
    let freshText = (try? String(contentsOfFile: s.notes.first { $0.id == fresh.id }!.path, encoding: .utf8)) ?? ""
    check("dismissing a one-off edits the file: the remind keys are gone", !freshText.contains("remind_at") && !freshText.contains("remind_on") && !r.ringing.contains(fresh.id), freshText)
    r.dismiss(daily.id, notes: s, now: now)
    let dailyText = (try? String(contentsOfFile: s.notes.first { $0.id == daily.id }!.path, encoding: .utf8)) ?? ""
    let moved = s.notes.first { $0.id == daily.id }?.remindAt
    check("dismissing a repeating one moves remind_at to the next time and keeps the rhythm", (moved ?? .distantPast) > now && dailyText.contains("remind_repeat: daily"), dailyText)

    // the other device dismissed it: its keys are cleared in the synced file, and the ring here stops
    var cleared = s.notes.first { $0.id == persistLate.id }!
    cleared.remindAt = nil; cleared.remindOn = nil; cleared.remindPersist = false
    s.update(cleared)
    r.check(s.notes, now: now.addingTimeInterval(10))
    check("a dismissal made elsewhere stops the ring here", !r.ringing.contains(persistLate.id))

    let t = ISO8601DateFormatter().date(from: "2026-01-31T09:00:00Z")!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    // S3: dismissing changes only the reminder keys of the file as it is now; words another app wrote a moment ago survive
    let guarded = make("words guarded", at: -10)
    var onDisk = (try? String(contentsOfFile: s.notes.first { $0.id == guarded.id }!.path, encoding: .utf8)) ?? ""
    onDisk += "\nwritten by another app after the last read\n"
    try? onDisk.write(toFile: s.notes.first { $0.id == guarded.id }!.path, atomically: true, encoding: .utf8)
    r.dismiss(guarded.id, notes: s, now: now)
    let afterDismiss = (try? String(contentsOfFile: s.notes.first { $0.id == guarded.id }!.path, encoding: .utf8)) ?? ""
    check("dismissing keeps words another app wrote since the last read", afterDismiss.contains("written by another app after the last read") && !afterDismiss.contains("remind_at"), afterDismiss)

    // S18: times other writers give
    check("a time with fractions and a bare date both read", NotesStore.parseDate("2026-11-01T09:00:00.123Z") != nil && NotesStore.parseDate("2026-11-01") != nil
          && NotesStore.parseDate("not a time") == nil)

    // S25: a final space stays through a save and a read
    let checkbox = NotesStore.parse(id: "cb", "---\ntitle: \"T\"\n---\n- [ ] one\n- [ ] \n")
    check("a last empty checkbox keeps its space through a read and a write",
          checkbox?.body == "- [ ] one\n- [ ] " && NotesStore.parse(id: "cb", NotesStore.render(checkbox!))?.body == "- [ ] one\n- [ ] ", "\(String(describing: checkbox?.body))")

    // S12: markers pasted into an ordinary note do not cost it its header
    var pasted = Note(id: "pp", title: "Real title", body: "```\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n```", tags: ["keep"], created: now)
    pasted.pinned = true
    let pastedText = NotesStore.render(pasted)
    check("markers pasted into a normal note keep its title, tags and pin on a save", pastedText.hasPrefix("---\ntitle: \"Real title\"") && pastedText.contains("tags: \"keep\"") && pastedText.contains("pinned: true"), pastedText)

    // S11: a clash settled by hand reads its header again
    let clashText = "---\ntitle: \"Real title\"\ntags: \"a, b\"\n---\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> origin/main\n"
    try? clashText.write(toFile: NotesStore.dir + "/hand.md", atomically: true, encoding: .utf8)
    s.load()
    var handNote = s.notes.first { $0.id == "hand" }!
    handNote.body = "---\ntitle: \"Real title\"\ntags: \"a, b\"\nremind_at: 2031-01-01T09:00:00Z\n---\nsettled words"
    s.update(handNote)
    let settled = s.notes.first { $0.id == "hand" }
    check("a clash settled by deleting the markers by hand gets its header back as title, tags and reminder",
          settled?.title == "Real title" && settled?.tags == ["a", "b"] && settled?.remindAt != nil && settled?.body == "settled words", "\(String(describing: settled))")

    check("the Reminders.app alarm is set two minutes after the due time", ReminderBackend.alarmDate(forDue: now) == now.addingTimeInterval(120))
    check("a weekly reminder steps a week at a time past now", ReminderRinger.next(after: t.addingTimeInterval(86_400 * 10), from: t, every: .weekly, calendar: cal) == t.addingTimeInterval(86_400 * 14))
    return lines
}
