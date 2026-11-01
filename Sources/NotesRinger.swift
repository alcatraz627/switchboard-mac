// NotesRinger.swift
// Rings a note's reminder on this Mac: a sound until it is dismissed, plus a notification with a Dismiss button.
// It runs from the app, not from any panel, off a timer that reads the notes this Mac holds. A reminder belongs to
// the one device in `remind_on`; this Mac rings only the ones for the Mac, and never touches the phone's.
// Dismissing is a file edit, so it syncs and clears the reminder on the other device too: a one-off loses its
// `remind_*` keys, a repeating one moves `remind_at` to the next time. A time that passed and was not dismissed
// stays visible on the note as missed.

import AppKit
import UserNotifications

final class ReminderRinger: ObservableObject {
    static let shared = ReminderRinger(persist: true)
    static let category = "switchboard.reminder"
    static let handledKey = "switchboard.notes.ringHandled"

    /// Only the app's own ringer remembers across launches; a probe's ringer starts clean.
    private let persist: Bool
    init(persist: Bool = false) {
        self.persist = persist
        if persist { handled = Set(AppDefaults.store.stringArray(forKey: Self.handledKey) ?? []) }
    }

    /// Notes ringing now; each shows a Dismiss on its row and in its notification.
    @Published private(set) var ringing: Set<String> = []
    /// `id@time` of every reminder time that has rung, so one time rings once, even across a relaunch.
    private var handled: Set<String> = [] {
        didSet {
            guard persist else { return }
            // kept short: a time older than the last 300 is long past any chance of ringing again
            AppDefaults.store.set(Array(handled.sorted().suffix(300)), forKey: Self.handledKey)
        }
    }
    private var tick: Timer?
    private var beat: Timer?
    private var started: [String: Date] = [:]

    /// Chimes so far; the probe counts them with the sound off.
    private(set) var chimes = 0
    var chimeAloud = true
    /// How a ring is announced; a probe replaces it to count notifications.
    var announce: (Note) -> Void = ReminderRinger.postNotification

    /// True once the app is watching reminders, so its own ring covers them and Reminders.app gets no copy.
    var canRing: Bool { tick != nil }

    // ── Which reminders are due ─────────────────────────────────────────────

    /// A reminder this Mac rings: it has a time, that time has come, and its device is the Mac (left out means the Mac).
    static func dueHere(_ n: Note, now: Date) -> Bool {
        guard let at = n.remindAt, at <= now else { return false }
        return n.remindOn == nil || n.remindOn == "mac"
    }

    /// True for a reminder whose time passed and that is not ringing now: shown as missed until dismissed.
    func missed(_ n: Note, now: Date = Date()) -> Bool {
        guard let at = n.remindAt, at <= now else { return false }
        return !ringing.contains(n.id)
    }

    /// The latest time a repeating reminder fell on or before `now`, stepping from `from` by its own rhythm.
    static func latest(onOrBefore now: Date, from: Date, every r: Note.Repeat, calendar: Calendar = .current) -> Date {
        var t = from
        var steps = 0
        while steps < 5000 {
            let n = next(after: t, from: t, every: r, calendar: calendar)
            if n > now || n <= t { break }
            t = n; steps += 1
        }
        return t
    }

    /// The next time a repeating reminder falls after `now`, stepping from `from` by its own rhythm.
    static func next(after now: Date, from: Date, every r: Note.Repeat, calendar: Calendar = .current) -> Date {
        let unit: Calendar.Component
        switch r { case .daily: unit = .day; case .weekly: unit = .weekOfYear; case .monthly: unit = .month; case .never: return from }
        var t = from
        var guardSteps = 0
        while t <= now, guardSteps < 5000 {
            t = calendar.date(byAdding: unit, value: 1, to: t) ?? t.addingTimeInterval(86_400)
            guardSteps += 1
        }
        return t
    }

    // ── Running ─────────────────────────────────────────────────────────────

    /// Starts watching, from the app, with no panel needed: every few seconds it reads the notes this Mac holds.
    func start() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check(NotesStore.shared.notes) }
        DispatchQueue.main.async { self.check(NotesStore.shared.notes) }
    }

    /// Stops watching; a probe uses it after starting the shared ringer.
    func stopWatching() { tick?.invalidate(); tick = nil }

    /// One look at the notes: ring what has come due and is not handled; stop what was dismissed elsewhere.
    func check(_ notes: [Note], now: Date = Date()) {
        // a reminder dismissed on the other device (its keys cleared or moved) stops ringing here
        for id in ringing where !(notes.first { $0.id == id }.map { Self.dueHere($0, now: now) } ?? false) { stopRing(id) }
        for n in notes where Self.dueHere(n, now: now) {
            guard let at = n.remindAt else { continue }
            // a repeating reminder nobody dismissed rings at each of its times, not only the first
            let slot = n.remindRepeat == .never ? at : Self.latest(onOrBefore: now, from: at, every: n.remindRepeat)
            let key = n.id + "@" + String(Int(slot.timeIntervalSince1970))
            guard !handled.contains(key) else { continue }
            handled.insert(key)
            // however late: a due reminder announces and rings once the first time the app can, then stays as missed
            startRing(n, now: now)
        }
        // a non-persistent ring ends after the chosen length; the reminder then stays missed
        let length = TimerStore.ringSeconds == 0 ? TimerStore.ringCap : TimerStore.ringSeconds
        for id in ringing where notes.first(where: { $0.id == id })?.remindPersist != true {
            if let s = started[id], now.timeIntervalSince(s) > Double(length) { stopRing(id) }
        }
    }

    private func startRing(_ n: Note, now: Date) {
        ringing.insert(n.id)
        started[n.id] = now
        chime()
        announce(n)
        dlog("reminder rings: \(n.title)")
        guard beat == nil else { return }
        var count = 0
        beat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            count += 1
            if self.ringing.isEmpty { self.beat?.invalidate(); self.beat = nil; return }
            self.chime()
            // macOS hides a banner after a few seconds; put it back every 20
            if count % 10 == 0 { for id in self.ringing { if let n = NotesStore.shared.notes.first(where: { $0.id == id }) { self.announce(n) } } }
        }
    }

    private func stopRing(_ id: String) {
        ringing.remove(id)
        started[id] = nil
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["reminder-" + id]) }
        if ringing.isEmpty { beat?.invalidate(); beat = nil }
    }

    private func chime() {
        chimes += 1
        guard chimeAloud else { return }
        let name = TimerStore.soundName
        _ = (NSSound(named: name) ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true))?.play()
    }

    // ── Dismissing ──────────────────────────────────────────────────────────

    /// Dismiss: the ring stops and the note is edited. A one-off loses its reminder keys; a repeating reminder moves to
    /// its next time. The edit syncs, which clears the reminder on the other device.
    /// The edit is made on the file as it is on disk now, so words another app wrote a moment ago are kept, and only
    /// when the reminder is due: an answer to an old notification after the reminder was moved changes nothing.
    /// `expectedAt` is the time the notification was about; a different time on the file means it is stale.
    func dismiss(_ id: String, notes: NotesStore = .shared, now: Date = Date(), expectedAt: Date? = nil) {
        stopRing(id)
        let changed = notes.patch(id, reason: "reminder dismissed") { r in
            guard let at = r.remindAt.flatMap(NotesStore.parseDate), at <= now else { return }
            if let e = expectedAt, abs(at.timeIntervalSince(e)) > 1 { return }
            if let rep = r.remindRepeat.flatMap(Note.Repeat.init(rawValue:)), rep != .never {
                r.remindAt = NotesStore.isoString(Self.next(after: now, from: at, every: rep))
            } else {
                r.remindAt = nil; r.remindRepeat = nil; r.remindOn = nil; r.remindPersist = false
            }
        }
        if changed { notes.refreshReminderItem(id) }
    }

    // ── The notification ────────────────────────────────────────────────────

    static func postNotification(_ n: Note) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = n.heading
        c.body = "Reminder" + (n.remindPersist ? ", rings until you dismiss it" : "")
        c.categoryIdentifier = category
        c.userInfo = ["note": n.id, "at": n.remindAt?.timeIntervalSince1970 ?? 0]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reminder-" + n.id, content: c, trigger: nil)) { err in
            if let err { dwarn("reminder notification not added: \(fmtErr(err))") }
        }
    }

    static func registerCategory(into others: [UNNotificationCategory]) -> Set<UNNotificationCategory> {
        let dismiss = UNNotificationAction(identifier: "dismiss", title: "Dismiss", options: [], icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        return Set(others + [UNNotificationCategory(identifier: category, actions: [dismiss], intentIdentifiers: [], options: [.customDismissAction])])
    }
}
