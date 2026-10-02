// Timers.swift
// Countdown timers the owner starts from the panel: several at once, each with
// a label and a colour, going off as a macOS notification with a sound. The
// Clock app's timers have no API, so these are Switchboard's own; they are
// saved, so a restart keeps them running.

import AppKit
import SwiftUI
import UserNotifications

struct SBTimer: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var label: String
    var color: String
    var start: Date
    var fireAt: Date
    var firedAt: Date?

    var running: Bool { firedAt == nil }
    var total: TimeInterval { max(1, fireAt.timeIntervalSince(start)) }
}

/// The eight tag colours timers and notes wear, by name so they survive on disk:
/// the Reminders set, spread around the wheel so no two are easily confused.
/// macOS system colours, so each adapts to dark and light.
let timerColors: [(String, Color)] = [
    ("red", Color(nsColor: .systemRed)), ("orange", Color(nsColor: .systemOrange)),
    ("yellow", Color(nsColor: .systemYellow)), ("green", Color(nsColor: .systemGreen)),
    ("teal", Color(nsColor: .systemTeal)), ("blue", Color(nsColor: .systemBlue)),
    ("purple", Color(nsColor: .systemPurple)), ("pink", Color(nsColor: .systemPink)),
]
/// Names saved under earlier sets, and where each one lands now.
let legacyTagColors = ["indigo": "purple", "mint": "green", "brown": "orange", "gray": "blue", "cyan": "teal"]
/// A saved colour name as one of the eight, or nil when it is none of them.
func tagColorName(_ name: String) -> String? {
    let n = legacyTagColors[name] ?? name
    return timerColors.contains { $0.0 == n } ? n : nil
}
func timerColor(_ name: String) -> Color { timerColors.first { $0.0 == tagColorName(name) }?.1 ?? Color(nsColor: .systemBlue) }

final class TimerStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = TimerStore()
    /// Probes and demo snapshots point this elsewhere so they never touch real timers.
    static var key = "switchboard.timers.countdowns"

    /// Stops this store's clocks, for stores a probe makes and drops.
    func stop() { tick?.invalidate(); tick = nil; silence() }

    @Published private(set) var timers: [SBTimer] = []
    /// Ticks once a second while a timer runs, so countdowns redraw.
    @Published private(set) var now = Date()
    /// macOS has Switchboard's notifications off, so a timer shows no banner
    /// and its notification makes no sound; the chime still rings.
    @Published var notificationsOff = false
    private var tick: Timer?
    private var ring: Timer?
    /// Set when the saved timers could not be read and the list started empty.
    @Published var loadError: String?

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: Self.key) {
            if let t = try? JSONDecoder().decode([SBTimer].self, from: d) {
                timers = t
            } else {
                // Keep the damaged copy aside: the next save would otherwise overwrite it for good.
                UserDefaults.standard.set(d, forKey: Self.key + ".unreadable")
                loadError = "The saved timers could not be read, so the list started empty."
                dwarn("timers: saved list could not be decoded; kept under \(Self.key).unreadable")
            }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            checkNotifications()
        }
        resume()
    }

    /// Reads whether macOS will show Switchboard's notifications at all.
    func checkNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let off = s.authorizationStatus == .denied || (s.authorizationStatus != .notDetermined && s.alertSetting != .enabled)
            DispatchQueue.main.async { self.notificationsOff = off }
        }
    }

    /// Rings every 2 s for up to 30 s, so a single short chime is not missed.
    /// Opening the panel stops it.
    private func startRinging() {
        ring?.invalidate()
        var left = 15
        chime()
        ring = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            left -= 1
            if left <= 0 { self?.silence() } else { self?.chime() }
        }
    }

    func silence() { ring?.invalidate(); ring = nil }

    /// Chimes so far; the probe counts them with the sound off.
    private(set) var chimes = 0
    var chimeAloud = true

    private func chime() {
        chimes += 1
        guard chimeAloud else { return }
        let played = (NSSound(named: "Glass") ?? NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true))?.play() ?? false
        if !played { dwarn("timer chime could not play") }
    }

    /// A menu bar app counts as in front, and macOS hides a notification from
    /// the app in front unless asked to show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    var running: [SBTimer] { timers.filter(\.running).sorted { $0.fireAt < $1.fireAt } }

    func add(label: String, color: String, fireAt: Date) {
        let t = SBTimer(label: label.isEmpty ? "Timer" : label, color: color, start: Date(), fireAt: fireAt)
        timers.insert(t, at: 0)
        save()
        askToNotify()
        resume()
        remember(t)
    }

    /// The last few timers started, newest first, to start again in one click.
    struct Recent: Codable, Equatable { var label: String; var seconds: TimeInterval; var color: String }
    static let recentKey = "switchboard.timers.recent"
    @Published private(set) var recent: [Recent] = {
        guard let d = UserDefaults.standard.data(forKey: TimerStore.recentKey) else { return [] }
        return (try? JSONDecoder().decode([Recent].self, from: d)) ?? []
    }()
    private func remember(_ t: SBTimer) {
        let r = Recent(label: t.label, seconds: t.fireAt.timeIntervalSince(t.start).rounded(), color: t.color)
        recent = Self.recentList(adding: r, to: recent)
        if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: Self.recentKey) }
    }
    /// Newest first, one entry per label and length, five at most.
    static func recentList(adding r: Recent, to list: [Recent]) -> [Recent] {
        Array(([r] + list.filter { !($0.label == r.label && $0.seconds == r.seconds) }).prefix(5))
    }

    /// Moves a running timer by whole minutes, never closer than five seconds to now.
    func nudge(_ t: SBTimer, minutes: Int) {
        guard let i = timers.firstIndex(where: { $0.id == t.id }), timers[i].running else { return }
        timers[i].fireAt = max(Date().addingTimeInterval(5), timers[i].fireAt.addingTimeInterval(Double(minutes) * 60))
        save(); resume()
    }

    func extend(_ t: SBTimer, by seconds: TimeInterval) {
        guard let i = timers.firstIndex(where: { $0.id == t.id }) else { return }
        let base = timers[i].running ? timers[i].fireAt : Date()
        timers[i].fireAt = base.addingTimeInterval(seconds)
        if !timers[i].running { timers[i].start = Date() }
        timers[i].firedAt = nil
        save(); resume()
    }

    func rename(_ t: SBTimer, to label: String) {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, let i = timers.firstIndex(where: { $0.id == t.id }) else { return }
        timers[i].label = l
        save()
    }

    func remove(_ t: SBTimer) {
        timers.removeAll { $0.id == t.id }
        save()
    }

    func move(_ dragged: String, to target: String) {
        timers = applyOrder(timers, reordered(timers.map(\.id), moving: dragged, to: target))
    }

    func save() {
        if let d = try? JSONEncoder().encode(timers) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Runs the one-second tick only while something counts down.
    private func resume() {
        guard tick == nil, timers.contains(where: \.running) else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
    }

    private func step() {
        now = Date()
        var changed = false
        for i in timers.indices where timers[i].running && timers[i].fireAt <= now {
            // One that came due while the app was closed keeps its real time and
            // does not ring at launch as if it just went off.
            let late = now.timeIntervalSince(timers[i].fireAt) > 120
            timers[i].firedAt = late ? timers[i].fireAt : now
            changed = true
            if late { dlog("timer went off while closed: \(timers[i].label)") } else { fire(timers[i]) }
        }
        if changed { save() }
        if !timers.contains(where: \.running) { tick?.invalidate(); tick = nil }
    }

    private func fire(_ t: SBTimer) {
        startRinging()
        dlog("timer fired: \(t.label)")
        guard Bundle.main.bundleIdentifier != nil else { return }   // the notification centre needs an app bundle
        let c = UNMutableNotificationContent()
        c.title = t.label
        c.body = "Timer done"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.id, content: c, trigger: nil)) { err in
            if let err = err { dwarn("timer notification not added: \(fmtErr(err))") }
        }
        checkNotifications()
    }

    /// Notification access is asked the first time a timer starts, never on launch.
    private func askToNotify() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // headless runs have no bundle
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err { dwarn("notification access: \(fmtErr(err))") }
            if !granted { dlog("notifications are off for Switchboard; timers ring in the app only") }
            self.checkNotifications()
        }
    }
}

// ── The tab ─────────────────────────────────────────────────────────────────

struct TimersTabView: View {
    @ObservedObject var timers: TimerStore
    @State private var label = ""
    @State private var color: String? = "blue"
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            if let e = timers.loadError {
                RowFailure(message: e, dismiss: { timers.loadError = nil })
            }
            // New timer: a name, a colour, then when. Enter in the name opens "when".
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Label, or \"25m tea\" to start at once", text: $label).textFieldStyle(.plain).font(PT.label)
                        .focused($focused)
                        // "25m tea" starts straight away; a plain name opens the picker
                        .onSubmit {
                            if let (sec, name) = TimerShorthand.parse(label) {
                                timers.add(label: name, color: color ?? "blue", fireAt: Date().addingTimeInterval(sec)); label = ""
                            } else { picking = true }
                        }
                        .onExitCommand { focused = false }
                        .inputBox(focused: focused)
                    WhenButton(title: "Start a timer for", presets: WhenPreset.timer,
                               onPick: { d, _ in timers.add(label: label, color: color ?? "blue", fireAt: d); label = "" },
                               isOpen: $picking) {
                        Label("Start", systemImage: "timer").font(.sb(11.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(timerColor(color ?? "blue").opacity(0.25)))
                    }
                    .help("Pick how long; the timer starts at once (Enter in the label opens this)")
                }
                ColorBalls(selection: $color)
                if !timers.recent.isEmpty {
                    // the last few timers, to start again in one click
                    FlowLayout(spacing: 5) {
                        ForEach(timers.recent, id: \.label) { r in
                            Button { timers.add(label: r.label, color: r.color, fireAt: Date().addingTimeInterval(r.seconds)) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise").font(.sbIcon(9.5))
                                    Text("\(clock(r.seconds)) \(r.label)").font(.sb(10.5))
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(timerColor(r.color).opacity(0.2)))
                            }
                            .buttonStyle(.plain).help("Start \(r.label) again for \(clock(r.seconds))")
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .onAppear {
                // the new timer's label gets the keyboard, unless a timer is being renamed
                guard InputRules.focusNewInput(editing: EditingState.shared.timer) else { return }
                DispatchQueue.main.async { focused = true }
            }
            if timers.notificationsOff {
                RowFailure(message: "macOS has Switchboard's notifications off, so a timer rings here with no banner.",
                           retry: {
                               let id = Bundle.main.bundleIdentifier ?? ""
                               if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                   NSWorkspace.shared.open(u)
                               }
                           },
                           retryLabel: "Open Settings",
                           dismiss: { timers.notificationsOff = false })
            }
            if timers.timers.isEmpty {
                Text("No timers. Name one, pick a colour, press Start.").font(PT.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                Card {
                    ReorderStack(items: timers.timers, move: { timers.move($0, to: $1) }, commit: { timers.save() }) { i, t, grip in
                        VStack(spacing: 0) {
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            TimerRow(timer: t, timers: timers, grip: grip)
                                .revealFlash("timer-" + t.id).id("timer-" + t.id)
                        }
                    }
                }
            }
        }
        .padding(PT.gap)
    }
}

struct TimerRow: View {
    let timer: SBTimer
    @ObservedObject var timers: TimerStore
    let grip: AnyView
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let left = timer.fireAt.timeIntervalSince(timers.now)
        HStack(spacing: 8) {
            grip
            Circle().fill(timerColor(timer.color)).frame(width: si(9), height: si(9))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // Click the label to rename it; Enter or clicking away saves.
                    if editing {
                        TextField("Label", text: $draft).textFieldStyle(.plain).font(PT.label)
                            .focused($focused)
                            .onSubmit { finish() }
                            .onChange(of: focused) { f in if !f { finish() } }
                            // Escape lets go of the keyboard; letting go saves, as clicking away does
                            .onExitCommand { focused = false }
                    } else {
                        Text(timer.label).font(PT.label)
                            .onTapGesture {
                                draft = timer.label; editing = true
                                EditingState.shared.timer = timer.id
                                NSApp.activate(ignoringOtherApps: true)
                                DispatchQueue.main.async { focused = true }
                            }
                            .help("Click to rename")
                    }
                    Spacer()
                    Text(timer.running ? clock(left) : "done").font(.sb(13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(timer.running ? .primary : timerColor(timer.color))
                }
                if timer.running {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(timerColor(timer.color))
                                .frame(width: g.size.width * CGFloat(max(0, min(1, 1 - left / timer.total))))
                        }
                    }
                    .frame(height: 4)
                } else if let f = timer.firedAt {
                    Text("went off " + age(f)).font(PT.caption).foregroundStyle(.secondary)
                }
            }
            Button { timers.extend(timer, by: 60) } label: { Image(systemName: "plus.circle").font(.sbIcon(11)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(timer.running ? "One more minute" : "Start again for a minute")
            Button { timers.remove(timer) } label: { Image(systemName: "xmark.circle").font(.sbIcon(11)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(timer.running ? "Cancel it" : "Clear it")
        }
        .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV + 1)
    }

    private func finish() {
        guard editing else { return }
        editing = false
        if EditingState.shared.timer == timer.id { EditingState.shared.timer = nil }
        timers.rename(timer, to: draft)
    }
}

/// Starts a one-second timer, lets it go off, extends and clears it, and
/// leaves the saved list as it found it.
func probeTimers() -> String {
    // A key of the probe's own: real timers are never read, cleared or rewritten.
    let realKey = TimerStore.key
    TimerStore.key = "switchboard.timers.countdowns.probe"
    defer { UserDefaults.standard.removeObject(forKey: TimerStore.key); TimerStore.key = realKey }
    UserDefaults.standard.removeObject(forKey: TimerStore.key)
    let s = TimerStore()
    defer { s.stop() }
    s.chimeAloud = false
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "ok  " : "FAIL") \(name)") }
    func pump(_ secs: Double) { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(secs)) }
    s.add(label: "Tea", color: "green", fireAt: Date().addingTimeInterval(1))
    check("a new timer runs", s.running.count == 1)
    let until = Date().addingTimeInterval(3)
    while Date() < until && !s.running.isEmpty { pump(0.1) }
    check("it goes off at its time", s.running.isEmpty && s.timers.first?.firedAt != nil)
    let rang = Date().addingTimeInterval(2.5)
    while Date() < rang { pump(0.1) }
    check("it keeps ringing, not one chime (\(s.chimes) so far)", s.chimes >= 2)
    s.silence()
    let heard = s.chimes
    let quiet = Date().addingTimeInterval(2.5)
    while Date() < quiet { pump(0.1) }
    check("opening the panel silences it", s.chimes == heard)
    let reopened = TimerStore()
    check("the fired state is saved", reopened.timers.first?.firedAt != nil)
    reopened.stop()
    s.extend(s.timers[0], by: 60)
    check("+ restarts a finished timer for a minute", s.running.count == 1 && abs(s.running[0].fireAt.timeIntervalSinceNow - 60) < 2)
    s.remove(s.timers[0])
    check("clearing removes it", s.timers.isEmpty)
    check("clock reads minutes and hours", clock(65) == "1:05" && clock(3725) == "1:02:05")

    // One that came due ten minutes ago, while the app was closed.
    let missed = SBTimer(label: "Missed", color: "red", start: Date().addingTimeInterval(-900), fireAt: Date().addingTimeInterval(-600))
    if let d = try? JSONEncoder().encode([missed]) { UserDefaults.standard.set(d, forKey: TimerStore.key) }
    let relaunched = TimerStore()
    relaunched.chimeAloud = false
    pump(1.5)
    let m = relaunched.timers.first
    check("a timer missed while closed keeps the time it was due",
          m?.firedAt.map { abs($0.timeIntervalSince(missed.fireAt)) < 1 } ?? false)
    check("and does not ring at launch", relaunched.chimes == 0)
    relaunched.stop()
    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

/// "4:05" under an hour, "1:02:30" over.
func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// A timer typed in one go: "25m tea", "tea 25m", "1h30 review", "90s". The
/// length can come first or last; whatever is left is the label.
enum TimerShorthand {
    static func parse(_ text: String) -> (seconds: TimeInterval, label: String)? {
        var words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        for at in [0, words.count - 1] {
            if let s = seconds(words[at]) {
                words.remove(at: at)
                return (s, words.joined(separator: " "))
            }
        }
        return nil
    }

    /// "25m", "1h", "1h30", "1h30m", "90s", "2h15m"; a bare number is not a length.
    static func seconds(_ w: String) -> TimeInterval? {
        // minutes may drop their "m" only after hours ("1h30"); otherwise "90s" would read as 9 minutes and 0 seconds
        let re = try! NSRegularExpression(pattern: #"^(?:(\d+)h(?:(\d+)m?)?|(\d+)m)?(?:(\d+)s)?$"#)
        let lower = w.lowercased()
        guard lower.rangeOfCharacter(from: CharacterSet(charactersIn: "hms")) != nil,
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }
        func n(_ i: Int) -> Double { Range(m.range(at: i), in: lower).flatMap { Double(lower[$0]) } ?? 0 }
        let total = n(1) * 3600 + (n(2) + n(3)) * 60 + n(4)
        return total > 0 ? total : nil
    }
}

/// The timer rules without starting one.
func probeTimerShorthand() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    func p(_ s: String) -> String { TimerShorthand.parse(s).map { "\(Int($0.seconds)) \($0.label)" } ?? "nil" }
    check("25m tea starts 25 minutes named tea", p("25m tea") == "1500 tea", p("25m tea"))
    check("the length can come last", p("tea 25m") == "1500 tea", p("tea 25m"))
    check("1h30 review is an hour and a half", p("1h30 review") == "5400 review", p("1h30 review"))
    check("90s alone has no label", p("90s") == "90 ", p("90s"))
    check("a bare number is not a length", p("call 5") == "nil" && p("tea") == "nil", p("call 5"))
    let r = TimerStore.Recent(label: "tea", seconds: 300, color: "blue")
    let list = TimerStore.recentList(adding: r, to: [r, TimerStore.Recent(label: "x", seconds: 60, color: "red")])
    check("starting the same timer again does not list it twice", list.count == 2 && list.first == r)
    let now = Date(timeIntervalSince1970: 50_000)
    check("a note edited an hour ago stays a row on the hover card", Note.keepsRow(pinned: false, modified: now.addingTimeInterval(-3600), now: now))
    check("one edited three hours ago becomes a chip", !Note.keepsRow(pinned: false, modified: now.addingTimeInterval(-3 * 3600), now: now))
    check("a pinned note is always a row", Note.keepsRow(pinned: true, modified: nil, now: now))
    return lines
}
