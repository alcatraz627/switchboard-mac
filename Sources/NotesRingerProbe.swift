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
    check("a due reminder, a late persistent one and a due repeating one ring", r.ringing == [fresh.id, persistLate.id, daily.id], "\(r.ringing)")
    check("each ring raised a notification and a chime", shown.count == 3 && r.chimes >= 3, "\(shown.count) / \(r.chimes)")
    check("a late reminder that is not persistent does not ring, and stays visible as missed", !r.ringing.contains(plainLate.id) && r.missed(plainLate, now: now))
    check("a reminder for the phone is left alone: no ring, no error", !r.ringing.contains(phone.id) && !shown.contains(phone.id))
    check("a reminder in the future does not ring", !r.ringing.contains(future.id))
    r.check(s.notes, now: now.addingTimeInterval(5))
    check("one time rings once: a second look raises nothing new", shown.count == 3)

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
    check("a weekly reminder steps a week at a time past now", ReminderRinger.next(after: t.addingTimeInterval(86_400 * 10), from: t, every: .weekly, calendar: cal) == t.addingTimeInterval(86_400 * 14))
    return lines
}
