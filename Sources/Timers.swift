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
    static let defaultKey = "switchboard.timers.countdowns"
    static var key = defaultKey
    /// Only the real list tells the run files about itself; demo, drive and probe lists stay out of the notes folder.
    let recordsRuns: Bool
    weak var runHook: Runs?
    private var runs: Runs? { runHook ?? (recordsRuns && self === Self.shared ? Runs.shared : nil) }
    private func runEvent(_ id: String, _ e: RunEvent) {
        guard let t = timers.first(where: { $0.id == id }) else { return }
        runs?.timerEvent(t, e)
    }

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
        recordsRuns = Self.key == Self.defaultKey
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
            registerActions()
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

    // ── Ringing ─────────────────────────────────────────────────────────────
    static let soundKey = "switchboard.timers.sound"
    static let ringKey = "switchboard.timers.ringSeconds"
    /// The sound a timer rings with, by its macOS name.
    static var soundName: String { UserDefaults.standard.string(forKey: soundKey) ?? "Glass" }
    /// How long a timer rings; 0 rings until stopped, capped so a forgotten one ends.
    static var ringSeconds: Int { UserDefaults.standard.object(forKey: ringKey) as? Int ?? 0 }
    static let ringChoices: [(seconds: Int, title: String)] = [(30, "30 s"), (60, "1 min"), (300, "5 min"), (0, "Until stopped")]
    static let ringCap = 60 * 60
    /// Every sound macOS ships, for the picker.
    static var sounds: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
            .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// The timers ringing now; each shows a Stop until it is answered.
    @Published private(set) var ringing: Set<String> = []

    /// Rings every 2 s until stopped or for the chosen length, and puts the
    /// notification back every 20 s, since macOS hides a banner after a few seconds.
    private func startRinging(_ t: SBTimer) {
        ringing.insert(t.id)
        ring?.invalidate()
        let length = Self.ringSeconds == 0 ? Self.ringCap : Self.ringSeconds
        var left = max(1, length / 2), beat = 0
        chime()
        ring = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            left -= 1; beat += 1
            if left <= 0 {   // timed out: the notification stays up
                let over = self.ringing
                self.ring?.invalidate(); self.ring = nil; self.ringing = []
                for id in over { self.runEvent(id, .answered) }
                return
            }
            self.chime()
            if beat % 10 == 0 { for id in self.ringing { if let r = self.timers.first(where: { $0.id == id }) { self.notify(r) } } }
        }
    }

    /// Stops every ring and takes its notification down.
    func silence() {
        ring?.invalidate(); ring = nil
        guard !ringing.isEmpty else { return }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(ringing))
        }
        let over = ringing
        ringing = []
        for id in over { runEvent(id, .answered) }
    }

    /// Chimes so far; the probe counts them with the sound off.
    private(set) var chimes = 0
    var chimeAloud = true

    private func chime() {
        chimes += 1
        guard chimeAloud else { return }
        let name = Self.soundName
        let played = (NSSound(named: name) ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true))?.play() ?? false
        if !played { dwarn("timer chime could not play: \(name)") }
    }

    /// Plays the chosen sound once, for the picker.
    static func preview(_ name: String) {
        (NSSound(named: name) ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true))?.play()
    }

    /// The notification's own buttons: stop the ring, or give it more time.
    static let category = "switchboard.timer"
    private func registerActions() {
        let stop = UNNotificationAction(identifier: "stop", title: "Stop", options: [], icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        let one = UNNotificationAction(identifier: "plus1", title: "+1 min", options: [], icon: UNNotificationActionIcon(systemImageName: "plus"))
        let five = UNNotificationAction(identifier: "plus5", title: "+5 min", options: [], icon: UNNotificationActionIcon(systemImageName: "plus"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [stop, one, five], intentIdentifiers: [], options: [.customDismissAction]),
        ])
    }

    /// Any answer to the notification stops the ring; the +1 and +5 buttons also restart the timer.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            self.silence()
            if let t = self.timers.first(where: { $0.id == id }) {
                if action == "plus1" { self.extend(t, by: 60) } else if action == "plus5" { self.extend(t, by: 300) }
            }
            done()
        }
    }

    /// A menu bar app counts as in front, and macOS hides a notification from
    /// the app in front unless asked to show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    var running: [SBTimer] { timers.filter(\.running).sorted { $0.fireAt < $1.fireAt } }

    /// Starts a timer. `id` is the run's name when it came from a request file, and `remember: false` keeps a
    /// timer someone else asked for out of the quick-start chips. Any other start names itself r-… and tells the run files.
    func add(label: String, color: String, fireAt: Date, id: String? = nil, start: Date? = nil, remember keep: Bool = true) {
        var t = SBTimer(label: label.isEmpty ? "Timer" : label, color: color, start: start ?? Date(), fireAt: fireAt)
        t.id = id ?? (runs != nil ? runs!.newID() : t.id)
        timers.insert(t, at: 0)
        save()
        askToNotify()
        resume()
        if keep { remember(t) }
        runEvent(t.id, .started)
    }

    /// The last few timers started, newest first, to start again in one click.
    struct Recent: Codable, Hashable { var label: String; var seconds: TimeInterval; var color: String }
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
        runEvent(t.id, .rescheduled)
    }

    func extend(_ t: SBTimer, by seconds: TimeInterval) {
        guard let i = timers.firstIndex(where: { $0.id == t.id }) else { return }
        let base = timers[i].running ? timers[i].fireAt : Date()
        timers[i].fireAt = base.addingTimeInterval(seconds)
        if !timers[i].running { timers[i].start = Date() }
        timers[i].firedAt = nil
        stopRinging(t.id)   // restarting a ringing timer answers it
        save(); resume()
        runEvent(t.id, .rescheduled)
    }

    /// Stops one timer's ring; the chime goes quiet once none is left ringing.
    func stopRinging(_ id: String) {
        guard ringing.contains(id) else { return }
        ringing.remove(id)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
        if ringing.isEmpty { ring?.invalidate(); ring = nil }
        runEvent(id, .answered)
    }

    func rename(_ t: SBTimer, to label: String) {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, let i = timers.firstIndex(where: { $0.id == t.id }) else { return }
        timers[i].label = l
        save()
    }

    func remove(_ t: SBTimer) {
        stopRinging(t.id)   // a cleared timer must not keep ringing with nothing on screen to stop it
        // the run files hear of it while the timer is still in the list, so they can tell stopped from done
        if let now = timers.first(where: { $0.id == t.id }) { runs?.timerEvent(now, .removed) }
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
            if late { dlog("timer went off while closed: \(timers[i].label)"); runEvent(timers[i].id, .missed) } else { fire(timers[i]) }
        }
        if changed { save() }
        if !timers.contains(where: \.running) { tick?.invalidate(); tick = nil }
    }

    private func fire(_ t: SBTimer) {
        startRinging(t)
        runEvent(t.id, .ringing)
        dlog("timer fired: \(t.label)")
        notify(t)
        checkNotifications()
    }

    /// Posts (or puts back) the timer's notification, with Stop and more time.
    private func notify(_ t: SBTimer) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // the notification centre needs an app bundle
        let c = UNMutableNotificationContent()
        c.title = t.label
        c.body = "Timer done."
        c.categoryIdentifier = Self.category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.id, content: c, trigger: nil)) { err in
            if let err = err { dwarn("timer notification not added: \(fmtErr(err))") }
        }
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
    @Environment(\.panelSpace) private var space

    var body: some View { TimersList(timers: timers, nav: RowNav.forSpace(space, "timers")) }
}

private struct TimersList: View {
    @ObservedObject var timers: TimerStore
    @ObservedObject var nav: RowNav
    @State private var label = ""
    @State private var color: String? = "blue"
    @State private var picking = false
    @FocusState private var focused: Bool
    @ObservedObject private var runs = Runs.shared
    /// Where the next timer runs: this Mac, or the phone. Starts on this Mac each time the tab opens.
    @State private var device = Runs.me

    private func start(_ label: String, _ color: String, _ fireAt: Date, template: String? = nil) {
        runs.start(label: label, color: color, fireAt: fireAt, on: device, template: template)
    }

    /// "Run on: This Mac" or "Phone": one choice for the next timer, its chips and templates.
    private var runOnMenu: some View {
        let phone = device == Runs.other
        return Menu {
            Button { device = Runs.me } label: { Label("This Mac", systemImage: phone ? "desktopcomputer" : "checkmark") }
            Button { device = Runs.other } label: { Label("Phone", systemImage: phone ? "checkmark" : "iphone") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: phone ? "iphone" : "desktopcomputer").font(.sbIcon(9.5))
                Text("Run on: " + (phone ? "Phone" : "This Mac")).font(.sb(10.5))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().strokeBorder(Color.primary.opacity(0.2)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Which device runs the next timer; a phone timer waits until the phone picks it up")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            if let e = timers.loadError {
                RowFailure(message: e, dismiss: { timers.loadError = nil })
            }
            // New timer: a name, a colour, then when. Enter in the name opens "when".
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // the timer's colour, the same dot a note wears; a timer always has one
                    ColorDot(selection: $color, allowNone: false, size: si(10))
                    TextField("Label, or \"25m tea\" to start at once", text: $label).textFieldStyle(.plain).font(PT.label)
                        .focused($focused)
                        // "25m tea" starts straight away; a plain name opens the picker
                        .onSubmit {
                            if let (sec, name) = TimerShorthand.parse(label) {
                                start(name, color ?? "blue", Date().addingTimeInterval(sec)); label = ""
                            } else { picking = true }
                        }
                        .onExitCommand { focused = false }
                        .inputBox(focused: focused)
                        .onChange(of: focused) { f in if f { nav.focus = .field } }
                        // ↑ from the first timer hands the label the keyboard again
                        .onChange(of: nav.focus) { f in if f == .field, !focused { focused = true } }
                    WhenButton(title: "Start a timer for", presets: WhenPreset.timer,
                               onPick: { d, _ in start(label, color ?? "blue", d); label = "" },
                               isOpen: $picking) {
                        Label("Start", systemImage: "timer").font(.sb(11.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(timerColor(color ?? "blue").opacity(0.25)))
                    }
                    .help("Pick how long; the timer starts at once (Enter in the label opens this)")
                }
                // the run-on choice, the templates every device shares, then the last few timers, to start again in one click
                FlowLayout(spacing: 5) {
                    runOnMenu
                    ForEach(runs.templates) { t in
                        Button { start(t.label, t.color.isEmpty ? "blue" : t.color, Date().addingTimeInterval(Double(t.minutes) * 60), template: t.id) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bookmark").font(.sbIcon(9.5))
                                Text("\(clock(Double(t.minutes) * 60)) \(t.label)").font(.sb(10.5))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(timerColor(t.color.isEmpty ? "blue" : t.color).opacity(0.2)))
                        }
                        .buttonStyle(.plain).help("Start \(t.label) for \(clock(Double(t.minutes) * 60)) on \(device == Runs.other ? "the phone" : "this Mac")")
                        .contextMenu { Button { runs.removeTemplate(t.id) } label: { Label("Remove template", systemImage: "trash") } }
                    }
                    ForEach(timers.recent, id: \.self) { r in
                        Button { start(r.label, r.color, Date().addingTimeInterval(r.seconds)) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise").font(.sbIcon(9.5))
                                Text("\(clock(r.seconds)) \(r.label)").font(.sb(10.5))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(timerColor(r.color).opacity(0.2)))
                        }
                        .buttonStyle(.plain).help("Start \(r.label) again for \(clock(r.seconds))")
                        .contextMenu {
                            Button { runs.saveTemplate(label: r.label, minutes: max(1, Int((r.seconds / 60).rounded())), color: r.color) } label: {
                                Label("Save as template", systemImage: "bookmark")
                            }
                        }
                    }
                }
                if let n = runs.notice {
                    Label(n, systemImage: "info.circle").font(PT.caption).foregroundStyle(.secondary)
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
                            TimerRow(timer: t, timers: timers, nav: nav, grip: grip)
                                .revealFlash("timer-" + t.id).id("timer-" + t.id)
                        }
                    }
                }
            }
            PhoneRunsSection(runs: runs)
        }
        .padding(PT.gap)
        .onAppear { runs.reload() }
    }
}

struct TimerRow: View {
    let timer: SBTimer
    @ObservedObject var timers: TimerStore
    @ObservedObject var nav: RowNav
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
                            .inputBox(focused: focused)
                            .onSubmit { finish() }
                            .onChange(of: focused) { f in if !f { finish() } }
                            // Escape lets go of the keyboard; letting go saves, as clicking away does
                            .onExitCommand { focused = false }
                    } else {
                        Text(timer.label).font(PT.label)
                            .onTapGesture { startRename() }
                            .help("Click to rename")
                    }
                    Spacer()
                    if timer.running {
                        Text(clock(left)).font(.sb(13, weight: .semibold).monospacedDigit())
                    } else if timers.ringing.contains(timer.id) {
                        Button { timers.stopRinging(timer.id) } label: { Label("Stop", systemImage: "bell.slash.fill") }
                            .buttonStyle(.borderedProminent).tint(timerColor(timer.color)).sbControlSize(.small)
                            .help("Stop the ring")
                    } else {
                        Label("Done", systemImage: "checkmark.circle").font(PT.caption).foregroundStyle(.secondary)
                    }
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
                if Runs.shared.records.first(where: { $0.id == timer.id })?.from == Runs.other {
                    Label("Started on the phone", systemImage: "iphone").font(PT.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Button { timers.extend(timer, by: 60) } label: { Image(systemName: "plus.circle").font(.sbIcon(11)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(timer.running ? "One more minute" : "Start again for a minute")
            Button { timers.remove(timer) } label: { Image(systemName: "xmark.circle").font(.sbIcon(11)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(timer.running ? "Cancel it" : "Clear it")
        }
        .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV + 1)
        .keyRing(nav.focus == .row(timer.id))
        // Return on the focused timer renames it, as a click on its name does
        .onChange(of: nav.renaming) { r in if r == timer.id, !editing { startRename() } }
    }

    private func startRename() {
        draft = timer.label; editing = true
        EditingState.shared.timer = timer.id
        nav.renaming = timer.id
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { focused = true }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        if EditingState.shared.timer == timer.id { EditingState.shared.timer = nil }
        if nav.renaming == timer.id { nav.renaming = nil }
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
    check("it shows as ringing until answered", s.ringing.count == 1)
    s.silence()
    let heard = s.chimes
    let quiet = Date().addingTimeInterval(2.5)
    while Date() < quiet { pump(0.1) }
    check("Stop silences it", s.chimes == heard && s.ringing.isEmpty)
    let reopened = TimerStore()
    check("the fired state is saved", reopened.timers.first?.firedAt != nil)
    reopened.stop()
    s.extend(s.timers[0], by: 60)
    check("+ restarts a finished timer for a minute", s.running.count == 1 && abs(s.running[0].fireAt.timeIntervalSinceNow - 60) < 2)
    s.remove(s.timers[0])
    check("clearing removes it", s.timers.isEmpty)

    // Answering a ring by restarting or clearing the timer stops the chime (review T-1, T-2).
    for (name, answer) in [("restarting a ringing timer stops its ring", { (t: SBTimer) in s.extend(t, by: 60) }),
                           ("clearing a ringing timer stops its ring", { (t: SBTimer) in s.remove(t) })] {
        s.add(label: "Ring", color: "blue", fireAt: Date().addingTimeInterval(1))
        let due = Date().addingTimeInterval(3)
        while Date() < due && s.ringing.isEmpty { pump(0.1) }
        guard let t = s.timers.first(where: { s.ringing.contains($0.id) }) else { check(name + " (it never rang)", false); continue }
        answer(t)
        let before = s.chimes
        let wait = Date().addingTimeInterval(2.5)
        while Date() < wait { pump(0.1) }
        check(name, s.ringing.isEmpty && s.chimes == before)
        for left in s.timers { s.remove(left) }
    }
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
