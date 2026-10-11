// QuickPages.swift
// The pages the hover card cycles through when the owner scrolls over the
// menu-bar icon: Home (the usual lines plus a row of status chips), then
// Limits, Approvals, Bulbs and Pinned notes. Each page lists what is active
// at full width and squeezes the rest into small chips; a chip makes its
// thing active, and every page has a button that opens its full tab.

import AppKit
import SwiftUI

enum QuickPage: String, CaseIterable {
    case sessions, home, limits, approvals, bulbs, notes, timers, controls, models

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .home: return "Now"
        case .limits: return "Limits"
        case .approvals: return "Approvals"
        case .bulbs: return "Bulbs"
        case .notes: return "Pinned notes"
        case .timers: return "Timers"
        case .controls: return "Controls"
        case .models: return "Local models"
        }
    }
    var icon: String {
        switch self {
        case .sessions: return "person.2.wave.2"
        case .home: return "house"
        case .limits: return Icons.tab["usage"] ?? "gauge"
        case .approvals: return Icons.tab["approvals"] ?? "hand.raised"
        case .bulbs: return "lightbulb"
        case .notes: return "pin"
        case .timers: return Icons.tab["timers"] ?? "timer"
        case .controls: return Icons.tab["controls"] ?? "slider.horizontal.3"
        case .models: return Icons.section["Local models"] ?? "cpu"
        }
    }
    /// The panel tab that shows this page in full.
    var tab: String? {
        switch self {
        case .sessions, .home: return nil
        case .limits: return "usage"
        case .approvals: return "approvals"
        case .bulbs: return "home"
        case .notes: return "notes"
        case .timers: return "timers"
        case .controls: return "controls"
        case .models: return "runtime"
        }
    }
}

/// Turns scroll-wheel movement into page turns: one page per push of the
/// wheel or swipe, never a run of pages from a single trackpad flick.
struct QuickCycle {
    typealias Phase = ScrollStepper.Phase

    /// The pages in the owner's order; scrolling and number keys walk this list.
    var pages: [QuickPage] = QuickPage.allCases
    private(set) var page: QuickPage = .home
    /// A swipe turns one page however long it runs; each wheel notch turns one, 0.2 s apart at most.
    private var stepper = ScrollStepper(perGesture: true, distance: 6, wheelPause: 0.2)

    /// One scroll event; true when the page changed. Content-style direction:
    /// scrolling the way that moves a list down goes forward.
    mutating func scroll(delta: CGFloat, precise: Bool, phase: Phase, momentum: Bool, at t: TimeInterval) -> Bool {
        let s = stepper.step(delta: delta, precise: precise, phase: phase, momentum: momentum, at: t)
        guard s != 0 else { return false }
        turn(s)
        return true
    }

    /// Wraps around at either end, so the card can be cycled in one direction.
    mutating func turn(_ by: Int) {
        let all = pages.isEmpty ? QuickPage.allCases : pages
        let i = all.firstIndex(of: page) ?? 0
        page = all[(i + by % all.count + all.count) % all.count]
    }

    /// Forgets any half-made gesture; the page stays where it was.
    mutating func forgetGesture() { stepper.reset() }
    /// Goes to a page. One that is no longer in the list falls back to the first.
    mutating func show(_ p: QuickPage) { page = pages.contains(p) ? p : (pages.first ?? .home) }

    /// The page a number key picks, 1 being the first in the owner's order.
    /// Nothing while a text field has the keyboard, so typing a digit stays typing.
    static func page(forKey chars: String, in pages: [QuickPage], typing: Bool) -> QuickPage? {
        guard !typing, chars.count == 1, let n = Int(chars), n >= 1, n <= pages.count else { return nil }
        return pages[n - 1]
    }

    /// Where a scroll happened, as far as page turning cares.
    enum Spot { case icon, card(fromTop: CGFloat), elsewhere }
    /// Scrolling turns pages over the menu-bar icon and the card's title bar;
    /// over the card's content it is left to the content.
    static func turnsPage(at spot: Spot, headerBottom: CGFloat) -> Bool {
        switch spot {
        case .icon: return true
        case .card(let y): return y >= 0 && y <= headerBottom
        case .elsewhere: return false
        }
    }
}

/// Checks the page-turning rules without a mouse.
func probeQuickCycle() -> String {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    // A swipe: began, many changed events, ended; then a second swipe.
    func swipe(_ c: inout QuickCycle, step: CGFloat, events: Int, from t0: TimeInterval) {
        _ = c.scroll(delta: step, precise: true, phase: .began, momentum: false, at: t0)
        for i in 1...events { _ = c.scroll(delta: step, precise: true, phase: .changed, momentum: false, at: t0 + Double(i) * 0.02) }
        _ = c.scroll(delta: 0, precise: true, phase: .ended, momentum: false, at: t0 + Double(events + 1) * 0.02)
    }
    var c = QuickCycle()
    check("starts on the usual card", c.page == .home)
    check("a nudge smaller than a step turns nothing",
          !c.scroll(delta: -2, precise: true, phase: .began, momentum: false, at: 0) && c.page == .home)
    c.forgetGesture()
    swipe(&c, step: -3, events: 60, from: 0)   // 1.2 s of continuous swiping
    check("a long swipe turns one page, not several", c.page == .limits, c.page.rawValue)
    swipe(&c, step: -3, events: 10, from: 5)
    check("the next swipe turns the next page", c.page == .approvals, c.page.rawValue)
    check("inertia after the finger lifts turns nothing",
          !c.scroll(delta: -40, precise: true, phase: .none, momentum: true, at: 6) && c.page == .approvals)
    var s = QuickCycle()
    _ = s.scroll(delta: -4, precise: true, phase: .changed, momentum: false, at: 0)
    check("half a swipe left behind is forgotten, not added to the next",
          !s.scroll(delta: -4, precise: true, phase: .changed, momentum: false, at: 600) && s.page == .home)
    var w = QuickCycle()
    check("one wheel notch turns a page", w.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 0) && w.page == .limits, w.page.rawValue)
    check("a fast spin steps, it does not race",
          !w.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 0.05) && w.page == .limits)
    check("the next notch after a pause turns again",
          w.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 0.5) && w.page == .approvals, w.page.rawValue)
    check("up goes back", w.scroll(delta: 1, precise: false, phase: .none, momentum: false, at: 1) && w.page == .limits, w.page.rawValue)
    var r = QuickCycle()
    r.show(.sessions)
    check("back from the first page wraps to the last",
          r.scroll(delta: 1, precise: false, phase: .none, momentum: false, at: 0) && r.page == .models, r.page.rawValue)
    check("forward from the last wraps to the first",
          r.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 1) && r.page == .sessions, r.page.rawValue)
    var d = QuickCycle()
    for (i, want) in [QuickPage.limits, .approvals, .bulbs, .notes, .timers, .controls, .models, .sessions, .home].enumerated() {
        _ = d.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: Double(i))
        if d.page != want { check("pages come in order", false, d.page.rawValue); return lines.joined(separator: "\n") }
    }
    check("pages come in order: sessions, now, limits, approvals, bulbs, pinned notes, timers, controls, local models", true)

    // The panel's tabs and sliders: a swipe steps every so many points, not once per swipe.
    var tabs = ScrollStepper.tabs()
    var moved = 0
    _ = tabs.step(delta: -3, precise: true, phase: .began, momentum: false, at: 0)
    for i in 1...30 { moved += tabs.step(delta: -3, precise: true, phase: .changed, momentum: false, at: Double(i) * 0.01) }
    check("a long swipe over the tabs steps several tabs, one per stretch", moved == 3, "\(moved)")
    check("inertia over the tabs steps nothing", tabs.step(delta: -50, precise: true, phase: .none, momentum: true, at: 1) == 0)
    var slide = ScrollStepper.slider()
    check("each wheel notch over a slider steps it", slide.step(delta: 1, precise: false, phase: .none, momentum: false, at: 0) == -1
          && slide.step(delta: 1, precise: false, phase: .none, momentum: false, at: 0.05) == -1)
    check("a slider moves 5% a step and stops at the ends",
          sliderStep(0.5, by: 1) == 0.55 && sliderStep(0.98, by: 1) == 1 && sliderStep(0.02, by: -1) == 0)
    check("a slider off the 5% grid lands on it", sliderStep(0.43, by: 1) == 0.5)
    check("tabs stop at the ends rather than wrap",
          stepped(["a", "b", "c"], from: "c", by: 1) == nil && stepped(["a", "b", "c"], from: "a", by: 1) == "b")
    let targets = ScrollTargets()
    targets.contentFrame = CGRect(x: 0, y: 100, width: 300, height: 400)
    targets.set("tabs", frame: CGRect(x: 0, y: 60, width: 300, height: 20), inContent: false, stepper: .tabs())
    targets.set("slider", frame: CGRect(x: 0, y: 50, width: 300, height: 20), inContent: true, stepper: .slider())
    check("a slider scrolled up under the header does not catch a scroll", targets.target(at: CGPoint(x: 10, y: 55)) == nil)
    check("the tab row does", targets.target(at: CGPoint(x: 10, y: 65)) == "tabs")

    // Where the card reopens: the page it last showed, or the first when that page is gone.
    var m = QuickCycle()
    m.show(.bulbs); m.forgetGesture()
    check("a new hover keeps the page the last one showed", m.page == .bulbs, m.page.rawValue)
    m.pages = [.limits, .notes, .home]
    m.show(.bulbs)
    check("a page no longer in the list falls back to the first", m.page == .limits, m.page.rawValue)
    _ = m.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 0)
    check("scrolling follows the owner's order", m.page == .notes, m.page.rawValue)

    // Hiding a page from the card.
    let hp = QuickCard.hidePlan(pages: [.home, .limits, .notes], current: .limits)
    check("hiding a page turns to the one after it", hp?.next == .notes && hp?.hide == "limits")
    check("hiding the last page turns to the one before it", QuickCard.hidePlan(pages: [.home, .limits], current: .limits)?.next == .home)
    check("the only page cannot be hidden", QuickCard.hidePlan(pages: [.home], current: .home) == nil)

    // The header's focus ring.
    check("a focused control stays unringed until the keyboard is used",
          !QuickState.ringShows(focused: "pill-home", id: "pill-home", keyboardDriven: false))
    check("after Tab the focused control is ringed", QuickState.ringShows(focused: "pill-home", id: "pill-home", keyboardDriven: true))
    check("only the one focused control is ringed",
          ["pill-home", "pill-limits", "hide", "desk", "open"].filter { QuickState.ringShows(focused: "hide", id: $0, keyboardDriven: true) } == ["hide"])
    check("nothing is ringed when nothing is focused",
          !QuickState.ringShows(focused: nil, id: "pill-home", keyboardDriven: true))

    // The dot beside a tab.
    let standing = Problem.hooks(unwired: 8, missing: 1) + [Problem(text: "1 gate is off", tab: "rules", level: .warn)]
    check("hook and gate warnings put no dot on their tab", Problem.tabMarks(standing).isEmpty)
    check("a failing job does, in red, even beside warnings",
          Problem.tabMarks(standing + [Problem(text: "nightly failed", tab: "runtime", level: .error)]) == ["runtime": .error])
    check("an error on the same tab as a warning shows as the error",
          Problem.tabMarks(standing + [Problem(text: "hook crashed", tab: "rules", level: .error)]) == ["rules": .error])

    // Number keys.
    let order: [QuickPage] = [.home, .limits, .approvals, .bulbs, .notes]
    check("2 opens the second page", QuickCycle.page(forKey: "2", in: order, typing: false) == .limits)
    check("a digit typed into a field turns nothing", QuickCycle.page(forKey: "2", in: order, typing: true) == nil)
    check("0 and keys past the last page turn nothing",
          QuickCycle.page(forKey: "0", in: order, typing: false) == nil && QuickCycle.page(forKey: "6", in: order, typing: false) == nil)
    check("letters turn nothing", QuickCycle.page(forKey: "a", in: order, typing: false) == nil)

    // Where scrolling turns pages.
    check("scrolling over the icon turns pages", QuickCycle.turnsPage(at: .icon, headerBottom: 34))
    check("scrolling over the title bar turns pages", QuickCycle.turnsPage(at: .card(fromTop: 12), headerBottom: 34))
    check("scrolling over the content does not", !QuickCycle.turnsPage(at: .card(fromTop: 90), headerBottom: 34))
    check("scrolling anywhere else does not", !QuickCycle.turnsPage(at: .elsewhere, headerBottom: 34))

    // Limits: Claude 5h and 7d, Codex 7d; no per-model or reserve rows.
    let cl = [UsageWindow(id: "five_hour", label: "5 hours", pct: 10, resetsAt: nil),
              UsageWindow(id: "seven_day", label: "Week", pct: 20, resetsAt: nil),
              UsageWindow(id: "seven_day_opus", label: "Week · opus", pct: 5, resetsAt: nil)]
    let cx = [UsageWindow(id: "codex.primary", label: "5 hours", pct: 1, resetsAt: nil),
              UsageWindow(id: "codex.secondary", label: "Week", pct: 30, resetsAt: nil),
              UsageWindow(id: "gpt-reserve.secondary", label: "Week · gpt-reserve", pct: 2, resetsAt: nil)]
    let bars = QuickCard.limitBars(claude: cl, codex: cx).map { "\($0.icon) \($0.span) \($0.w.pct)" }
    check("Settings knows every hover page", PolicyStore.quickPageIDs == QuickPage.allCases.map(\.rawValue))
    check("the mouse-away delay snaps to its steps, 0 included, and tops out at 15 s",
          PolicyStore.clampedLinger(0) == 0 && PolicyStore.clampedLinger(0.4) == 0.5 && PolicyStore.clampedLinger(40) == 15
          && PolicyStore.clampedLinger(7.6) == 8 && PolicyStore.clampedLinger(1) == 0.8)
    check("the new pages start hidden for someone who never saw them",
          PolicyStore.startingHidden(saved: [], seen: ["home", "limits", "approvals", "bulbs", "notes"]) == ["controls", "models"])
    check("the header offers Timers to someone who never changed the page list",
          !PolicyStore.startingHidden(saved: [], seen: []).contains("timers") && QuickPage.allCases.contains(.timers))
    check("Models stays an opt-in page", PolicyStore.startingHidden(saved: [], seen: []).contains("models"))
    let once = UserDefaults(suiteName: "sb-probe-timers-\(getpid())")!
    check("a saved hidden Timers is shown once, and hiding it again afterwards is kept",
          PolicyStore.timersShownOnce(["timers", "models"], defaults: once) == ["models"]
          && PolicyStore.timersShownOnce(["timers", "models"], defaults: once) == ["timers", "models"])
    once.removePersistentDomain(forName: "sb-probe-timers-\(getpid())")
    let tick = StatusBadge(id: "t", icon: "timer", text: "Tea", kind: .info, help: "", until: Date(timeIntervalSince1970: 1000))
    check("a timer badge counts down with the clock, not with when it was made",
          tick.text(at: Date(timeIntervalSince1970: 940)) == "Tea · 1:00" && tick.text(at: Date(timeIntervalSince1970: 970)) == "Tea · 0:30"
          && tick.text(at: Date(timeIntervalSince1970: 1100)) == "Tea · 0:00")
    check("a pinned note's Open and row click carry that note's id",
          NotesNav.focus(forRevealKey: NotesNav.revealKey("abc")) == .open("abc", nil, typing: false)
          && NotesNav.focus(forRevealKey: "timer-abc") == nil)
    check("a page the owner already switched on stays on",
          PolicyStore.startingHidden(saved: ["bulbs"], seen: PolicyStore.quickPageIDs) == ["bulbs"])
    check("a saved page order survives, a gone page drops out, a new one joins at the end",
          PolicyStore.mergedOrder(saved: ["notes", "gone", "home"], all: ["home", "limits", "notes"]) == ["notes", "home", "limits"])
    check("the Sessions page joins a saved order at the front",
          PolicyStore.mergedOrder(saved: ["home", "limits"], all: ["sessions", "home", "limits", "notes"]) == ["sessions", "home", "limits", "notes"])
    check("limits are Claude 5h, Claude 7d, Codex 7d", bars == ["sparkle 5h 10", "sparkle 7d 20", "terminal 7d 30"], bars.joined(separator: ", "))
    let many = Array(repeating: "Release work", count: 30)
    let fit = ChipFlow.fitting(many, rows: 2)
    check("thirty chips are cut to what two rows hold", fit > 2 && fit < 12, "\(fit)")
    check("a few short chips all fit", ChipFlow.fitting(["a", "b", "c"], rows: 2) == 3)
    return lines.joined(separator: "\n")
}

extension Problem {
    /// The dots beside tab and space names: errors only. A warning such as "8 hook scripts have no event"
    /// is a standing condition that never clears by itself, so a dot for it is furniture; the Now page badge still names it.
    static func tabMarks(_ ps: [Problem]) -> [String: ProblemLevel] {
        levels(ps.filter { $0.level == .error })
    }
}

/// What the card shows and which page it is on; the view follows it.
final class QuickState: ObservableObject {
    @Published var page: QuickPage = .home {
        willSet {
            // which way the turn went, read while the new page draws; going round the end still counts as onward
            guard let a = pages.firstIndex(of: page), let b = pages.firstIndex(of: newValue), a != b else { return }
            let n = pages.count
            forward = (a == n - 1 && b == 0) ? true : (a == 0 && b == n - 1) ? false : b > a
        }
    }
    /// The last page turn went onward through the pages, not back.
    private(set) var forward = true
    /// The pages in the owner's order.
    @Published var pages: [QuickPage] = QuickPage.allCases
    /// How far down the card the title bar ends, measured when it draws;
    /// scrolling above this line turns pages.
    var headerBottom: CGFloat = 34
    @Published var badges: [StatusBadge] = []
    /// The window space this card draws in; each desk panel has its own.
    var space = ScrollTargets.cardSpace
    /// A desk panel: it stays on screen, so it refreshes at a calmer pace than the hover card.
    var onDesk = false
    /// Set by a Tab or arrow key on the card, cleared when the card opens. The header's focus ring
    /// draws only while this is set, so nothing sits ringed just because the card appeared.
    @Published var keyboardDriven = false

    /// The header control that wears the ring: the focused one, and only after the keyboard was used.
    static func ringShows(focused: String?, id: String, keyboardDriven: Bool) -> Bool {
        keyboardDriven && focused == id
    }
}

/// One standard badge for something that needs the owner, coloured by how
/// much: broken, could use a look, waiting on you, or just running.
struct StatusBadge: Identifiable {
    enum Kind { case error, warn, waiting, info }
    let id: String
    let icon: String
    let text: String
    let kind: Kind
    let help: String
    var opens: QuickPage? = nil
    var tab: String? = nil
    /// The search that finds the badge's row in its tab.
    var query: String? = nil
    /// A countdown badge: `text` is its lead ("Tea") and the time left to this moment follows it, redrawn each second.
    var until: Date? = nil

    /// What the badge says at a moment; a countdown badge reads the time left then.
    func text(at now: Date) -> String {
        guard let until else { return text }
        return "\(text) · \(clock(max(0, until.timeIntervalSince(now))))"
    }

    var tint: Color {
        switch kind {
        case .error: return ProblemLevel.error.tint
        case .warn: return ProblemLevel.warn.tint
        case .waiting: return Color(nsColor: menuYellow)
        case .info: return .teal
        }
    }

    init(id: String, icon: String, text: String, kind: Kind, help: String,
         opens: QuickPage? = nil, tab: String? = nil, query: String? = nil, until: Date? = nil) {
        self.id = id; self.icon = icon; self.text = text; self.kind = kind; self.help = help
        self.opens = opens; self.tab = tab; self.query = query; self.until = until
    }

    init(problem p: Problem, index: Int) {
        self.init(id: "problem-\(index)", icon: p.level.icon, text: p.text, kind: p.level == .error ? .error : .warn,
                  help: "Open it in the panel", tab: p.tab, query: p.query)
    }
}

/// The badge itself, the one shape every status takes on the card.
struct StatusBadgeView: View {
    let badge: StatusBadge
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            // the colour rides on the icon and the fill; the words stay full contrast to read
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: badge.icon).font(.sbIcon(9.5, weight: .semibold)).foregroundStyle(badge.tint)
                if badge.until != nil {
                    // ticks each second while the card is open, as the Timers page does
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        Text(badge.text(at: t.date)).font(.sb(10.5, weight: .medium).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(badge.text).font(.sb(10.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(badge.tint.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(badge.tint.opacity(0.45), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).help(badge.help)
    }
}

/// The tabs the Now page offers as shortcuts, in grid order.
let quickLaunchTabs: [(id: String, title: String)] = [
    ("agents", "Agents"), ("rules", "Hooks"), ("notes", "Notes"),
    ("timers", "Timers"), ("controls", "Controls"), ("system", "Machine"),
]

extension View {
    /// A header control's own focus ring in place of the system one, which sat on the first icon
    /// as soon as the card opened. Drawn only for the focused control after a Tab or arrow key.
    func headerRing(_ id: String, _ focus: FocusState<String?>.Binding, _ state: QuickState, radius: CGFloat = 5) -> some View {
        focusEffectDisabled().focused(focus, equals: id)
            .keyRing(QuickState.ringShows(focused: focus.wrappedValue, id: id, keyboardDriven: state.keyboardDriven), radius: radius)
    }
}

/// The hover card: a header with the page's name and dots for every page,
/// then the page itself.
struct QuickCard: View {
    @ObservedObject var state: QuickState
    @Namespace private var pillSpace
    @ObservedObject var policy: PolicyStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var lights: LightsStore
    @ObservedObject var notes: NotesStore
    @ObservedObject var timers: TimerStore = .shared
    @ObservedObject var controls: ControlsStore
    @ObservedObject var sessions: SessionsStore = .shared
    let openTab: (String) -> Void
    /// Opens a tab with its search filled in, so the row a badge names is in view.
    var openSearch: (String, String) -> Void = { _, _ in }
    /// Opens a tab and lands on one row there, flashing it.
    var openReveal: (String, String) -> Void = { _, _ in }
    /// Pins a page to the desktop as a desk panel.
    var pin: ((QuickPage) -> Void)? = nil
    /// Why the footer's Hub button could not open the hub, if it could not.
    @State private var hubFailed: String?
    /// Which header control the keyboard is on; at most one, so at most one ring.
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // a desk panel names its page in its own title row, so it carries no second header
            if !state.onDesk {
                header
                    .background(GeometryReader { g in
                        Color.clear.onAppear { state.headerBottom = g.frame(in: .named(state.space)).maxY + 5 }
                    })
                Divider().padding(.horizontal, -12)
            }
            Group {
                switch state.page {
                case .sessions:
                    // ticks each second so "4s ago" and the waits stay current while it is open
                    TimelineView(.periodic(from: .now, by: 1)) { t in SessionsPage(store: sessions, now: t.date) }
                case .home: home
                case .limits: limits
                case .approvals: approvals
                case .bulbs: bulbs
                case .notes: pinned
                // ticks each second while the card is open, as Sessions does; the store's own
                // tick did not redraw an open card (owner: "only on close and reopen")
                case .timers: TimelineView(.periodic(from: .now, by: 1)) { t in timerPage(now: t.date) }
                case .controls: controlsPage
                case .models: modelsPage
                }
            }
            .id(state.page)
            .transition(Motion.turn(forward: state.forward))
            // the owner's footer, the same under every page: Hub, what waits, the Claude week
            if !state.onDesk {
                Divider().padding(.horizontal, -12)
                footer
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        // the hover card is a fixed width; a pinned page fills the window it is given
        .frame(width: state.onDesk ? nil : sw(320), alignment: .leading)
        .frame(minWidth: state.onDesk ? sw(320) : nil, maxWidth: state.onDesk ? .infinity : nil, alignment: .leading)
        .animation(Motion.fast, value: state.page)
        .background(GlassBackground())
        .coordinateSpace(name: state.space)
        .environment(\.cardSpace, state.space)
    }

    /// One pill per page, the panel's tab grammar in small: an icon each, the
    /// current one also named, a click or its number key goes there.
    private var header: some View {
        HStack(spacing: 4) {
            // the current page is named when the row has room; with many pages on, every pill is an icon.
            // A desk panel shows one page and names it in its own title row, so it needs no pills.
            if !state.onDesk { ViewThatFits(in: .horizontal) { pills(named: true); pills(named: false) } }
            Spacer(minLength: 4)
            if !state.onDesk, let plan = QuickCard.hidePlan(pages: state.pages, current: state.page) {
                Button {
                    state.page = plan.next
                    policy.hiddenQuickPages.insert(plan.hide)
                } label: {
                    Image(systemName: "eye.slash").font(.sbIcon(12, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).headerRing("hide", $focus, state)
                .help("Hide \(state.page.title) from the hover card. Bring it back in Settings, Hover card.")
            }
            if let pin, !state.onDesk {
                Button { pin(state.page) } label: {
                    // a floating window, not a pin: a pin is what notes carry
                    Image(systemName: "pip.enter").font(.sbIcon(12, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).headerRing("desk", $focus, state)
                .help("Pin \(state.page.title) to the desktop as a panel that stays up")
            }
            if let tab = state.page.tab {
                Button { openTab(tab) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.sbIcon(12, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).headerRing("open", $focus, state)
                .help("Open \(state.page.title) in the panel")
            } else {
                // Now has no tab of its own; its button opens the hover card's own settings
                Button { openSearch("settings", "hover") } label: {
                    Image(systemName: "gearshape").font(.sbIcon(12, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).headerRing("gear", $focus, state)
                .help("Hover card settings: pages, delay, what Now shows")
            }
        }
    }

    /// Hiding the page on show: the page to turn to first (the one after it, else the one before) and the id to hide.
    /// Nothing when it is the only page, so the card always has one.
    static func hidePlan(pages: [QuickPage], current: QuickPage) -> (next: QuickPage, hide: String)? {
        guard pages.count > 1, let i = pages.firstIndex(of: current) else { return nil }
        return (pages[i + 1 < pages.count ? i + 1 : i - 1], current.rawValue)
    }

    private func pills(named: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(state.pages.enumerated()), id: \.element) { i, p in
                let on = p == state.page
                Button { state.page = p } label: {
                    HStack(spacing: 4) {
                        Image(systemName: p.icon).font(.sbIcon(10, weight: .semibold))
                        if on && named { Text(p.title).font(.sb(11, weight: .semibold)).lineLimit(1).fixedSize() }
                    }
                    .padding(.horizontal, on && named ? 8 : 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    // the highlight travels from pill to pill rather than jumping
                    .background {
                        if on { Capsule().fill(Color.primary.opacity(0.1)).matchedGeometryEffect(id: "pill", in: pillSpace) }
                    }
                    .foregroundStyle(on ? .primary : .secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).headerRing("pill-" + p.rawValue, $focus, state, radius: 11).help("\(p.title) (\(i + 1))")
            }
        }
        .fixedSize()
    }

    // ── Now ─────────────────────────────────────────────────────────────────
    /// Two tiers: shortcuts to the tabs used most, then one badge per thing
    /// that needs the owner. Limits live on their own page.
    private var home: some View {
        let tabs = quickLaunchTabs.filter { !policy.hiddenTabs.contains($0.id) }.prefix(6)
        return VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(tabs), id: \.id) { t in
                    Button { openTab(t.id) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: Icons.tab[t.id] ?? "square").font(.sbIcon(10.5))
                            Text(t.title).font(.sb(11.5)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).help("Open \(t.title) in the panel")
                }
            }
            if state.badges.isEmpty {
                Text("Nothing needs you").font(.sb(11.5)).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(state.badges) { b in
                        StatusBadgeView(badge: b) {
                            if let p = b.opens { state.page = p }
                            else if let t = b.tab { if let q = b.query { openSearch(t, q) } else { openTab(t) } }
                        }
                        // a middle click always goes to the full tab, even for a badge that opens a hover page
                        .onMiddleClick("badge-" + b.id, space: state.space) {
                            if let t = b.tab ?? b.opens?.tab { if let q = b.query { openSearch(t, q) } else { openTab(t) } }
                        }
                    }
                }
            }
        }
    }

    // ── Limits ──────────────────────────────────────────────────────────────
    private var limits: some View {
        let bars = QuickCard.limitBars(claude: usage.claude, codex: usage.codex).map { icon, span, w in
            HoverLine.bar(label: span, pct: w.pct,
                          color: w.pct >= usage.dangerPct ? .red : w.pct >= usage.warnPct ? .orange : .green,
                          resets: w.resetsAt.map { $0 > Date() ? "in " + countdownText(to: $0, now: Date()) : "" } ?? "",
                          icon: icon)
        }
        return Group {
            if bars.isEmpty { empty("No limits read yet") } else { HoverLinesView(lines: bars, labelWidth: 40) }
        }
        .onAppear { usage.loadClaude() }   // fresh numbers even when the Limits hover item is off
    }

    /// The three limits the owner acts on: Claude 5h and 7d, Codex 7d. The
    /// icon says whose; per-model and reserve windows stay in the Usage tab.
    static func limitBars(claude: [UsageWindow], codex: [UsageWindow]) -> [(icon: String, span: String, w: UsageWindow)] {
        let claudeIcon = Icons.section["Claude"] ?? "sparkle", codexIcon = Icons.section["Codex"] ?? "terminal"
        let c = claude.compactMap { w -> (String, String, UsageWindow)? in
            w.id == "five_hour" ? (claudeIcon, "5h", w) : w.id == "seven_day" ? (claudeIcon, "7d", w) : nil
        }
        let x = codex.first { $0.id.hasPrefix("codex.") && $0.label == "Week" }
        return c + (x.map { [(codexIcon, "7d", $0)] } ?? [])
    }

    // ── Approvals ───────────────────────────────────────────────────────────
    /// The Approvals tab's groups in its order; only pushes and asks a live
    /// session waits on carry the yellow hand.
    private var approvals: some View {
        let groups = policy.needGroups.map { ($0.title, $0.rows.filter { !$0.buttons.isEmpty }) }.filter { !$0.1.isEmpty }
        let total = groups.reduce(0) { $0 + $1.1.count }
        // at most five rows in all, taken group by group in the tab's order
        var left = 5
        let shown: [(String, [SystemRow])] = groups.compactMap { title, rows in
            let take = Array(rows.prefix(left)); left -= take.count
            return take.isEmpty ? nil : (title, take)
        }
        return VStack(alignment: .leading, spacing: 7) {
            if groups.isEmpty { empty("Nothing waits on you") }
            ForEach(shown, id: \.0) { title, rows in
                Text(title).font(.sb(10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(rows) { r in
                    QuickNeedRow(row: r, waiting: title == "Pushes" || title == "Policy asks" || title == "Claude asks")
                        .onMiddleClick("qneed-" + (r.key ?? r.label), space: state.space) {
                            openReveal("approvals", r.key ?? r.label)
                        }
                }
            }
            if total > 5 { more(total - 5, tab: "approvals") }
        }
    }

    // ── The footer, under every page ────────────────────────────────────────
    /// Hub, then each push, ask or Claude prompt waiting on the owner as a line with
    /// its own answer buttons, then the Claude week bar, always. Nothing waiting
    /// shows no line at all, rather than a sentence saying so.
    private var footer: some View {
        // only what a live session waits on; leftovers from ended sessions stay on the Approvals page
        let live: Set<String> = ["Pushes", "Policy asks", "Claude asks"]
        let rows = state.page == .approvals || !policy.approvalsUnderEveryPage ? []
            : policy.needGroups.filter { live.contains($0.title) }.flatMap { g in g.rows.filter { !$0.buttons.isEmpty } }
        // the Limits page already draws the week
        let week = state.page == .limits ? nil : usage.claude.first { $0.id == "seven_day" }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Button { hubFailed = nil; SessionActions.openHub { hubFailed = $0 } } label: {
                    Label("Hub", systemImage: "rectangle.grid.2x2")
                }
                .buttonStyle(.borderless).font(.sb(11.5))
                .help("Open the session hub's board. Middle-click to open it in the browser.")
                .onMiddleClick("fhub", space: state.space) { hubFailed = nil; SessionActions.openHub(inBrowser: true) { hubFailed = $0 } }
                if !rows.isEmpty {
                    Button { state.page = .approvals } label: {
                        Label("\(rows.count) waiting on you", systemImage: "hand.raised.fill")
                    }
                    .buttonStyle(.borderless).font(.sb(11.5, weight: .medium)).foregroundStyle(Color(nsColor: menuYellow))
                    .help("Open the Approvals page")
                }
                Spacer()
            }
            if let f = hubFailed { Text(f).font(.sb(10.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(rows.prefix(3))) { r in
                QuickNeedRow(row: r)
                    .onMiddleClick("fneed-" + (r.key ?? r.label), space: state.space) { openReveal("approvals", r.key ?? r.label) }
            }
            if rows.count > 3 { more(rows.count - 3, tab: "approvals") }
            if let w = week {
                HoverLinesView(lines: [.bar(label: "7d", pct: w.pct,
                                            color: w.pct >= usage.dangerPct ? .red : w.pct >= usage.warnPct ? .orange : .green,
                                            resets: w.resetsAt.map { $0 > Date() ? "in " + countdownText(to: $0, now: Date()) : "" } ?? "",
                                            icon: Icons.section["Claude"] ?? "sparkle")], labelWidth: 40)
                    .help("Claude's weekly limit")
            }
        }
        .onAppear { usage.loadClaude() }
    }

    // ── Bulbs ───────────────────────────────────────────────────────────────
    /// Bulbs that are on, or were on in the last two hours, as rows; the rest as chips.
    /// A middle click on either opens the bulb in the Home tab and flashes it there.
    private var bulbs: some View {
        let rows = lights.bulbs.filter { LightsStore.keepsRow($0, lastOn: lights.lastOn[$0.mac]) }
        let chips = lights.bulbs.filter { !LightsStore.keepsRow($0, lastOn: lights.lastOn[$0.mac]) }
        return VStack(alignment: .leading, spacing: 5) {
            if lights.bulbs.isEmpty { empty(lights.discovering ? "Looking for bulbs…" : "No bulbs found") }
            ForEach(rows) { b in
                QuickBulbRow(bulb: b, lights: lights, lastOn: lights.lastOn[b.mac])
                    .onMiddleClick("qbulb-" + b.mac, space: state.space) { openReveal("home", BulbRow.revealKey(b.mac)) }
            }
            if !chips.isEmpty {
                ChipFlow(items: chips.map { b in
                    ChipItem(id: b.mac, icon: "lightbulb", text: b.title, enabled: b.reachable && !lights.busy.contains(b.mac),
                             help: b.reachable ? "Turn \(b.title) on. Middle-click to open it in Home." : "\(b.title) is not answering",
                             middle: { openReveal("home", BulbRow.revealKey(b.mac)) }) { lights.set(b, ["state=on"]) }
                })
            }
        }
        .onAppear {
            // bulbs are scanned when their tab opens; a page reached first, or a
            // list older than five minutes, scans now
            if !lights.discovering, (lights.lastScan?.timeIntervalSinceNow ?? -.infinity) < -300 { lights.discover() }
        }
    }

    // ── Pinned notes ────────────────────────────────────────────────────────
    private var pinned: some View {
        // pinned notes and ones edited in the last two hours are rows; the rest are chips
        let live = notes.live
        // one file read per note per draw
        let row = Dictionary(live.map { ($0.id, Note.keepsRow(pinned: $0.pinned, modified: $0.modified)) }, uniquingKeysWith: { a, _ in a })
        let pins = live.filter { row[$0.id] == true }
        let rest = live.filter { row[$0.id] != true }
        return VStack(alignment: .leading, spacing: 7) {
            if pins.isEmpty { empty("No pinned notes. Pin one below or in the Notes tab.") }
            ForEach(pins) { n in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: n.pinned ? "pin.fill" : "clock.arrow.circlepath").font(.sbIcon(9.5)).foregroundStyle(.secondary)
                        .help(n.pinned ? "Pinned" : "Edited in the last two hours")
                    // the note's colour, as the Notes tab shows it
                    if let c = n.color { Circle().fill(timerColor(c)).frame(width: si(7), height: si(7)) }
                    Text(n.heading).font(.sb(11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { openReveal("notes", NotesNav.revealKey(n.id)) } label: { Image(systemName: "square.and.pencil").font(.sbIcon(10.5)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open the note to read or edit")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(n.content, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.sbIcon(10.5)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Copy the note")
                    Button { var m = n; m.pinned.toggle(); notes.update(m) } label: {
                        Image(systemName: n.pinned ? "pin.slash" : "pin").font(.sbIcon(10.5))
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(n.pinned ? "Unpin" : "Pin")
                }
                // a click anywhere on the row opens the note, as its Open button does; the buttons keep their own clicks
                .contentShape(Rectangle())
                .onTapGesture { openReveal("notes", NotesNav.revealKey(n.id)) }
                .help("Open the note")
                .onMiddleClick("qnote-" + n.id, space: state.space) { openReveal("notes", NotesNav.revealKey(n.id)) }
            }
            createButton("New note", tab: "notes")
            if !rest.isEmpty {
                ChipFlow(items: rest.map { n in
                    ChipItem(id: n.id, icon: "pin", text: chipLabel(n.heading), enabled: true, help: "Pin \u{201C}\(n.heading)\u{201D}. Middle-click to open it in Notes.",
                             middle: { openReveal("notes", NotesNav.revealKey(n.id)) }) {
                        var m = n; m.pinned = true; notes.update(m)
                    }
                }, overflow: { more in
                    ChipItem(id: "more", icon: "ellipsis", text: "\(more) more", enabled: true, help: "Open the Notes tab") { openTab("notes") }
                })
            }
        }
    }

    // ── Timers ──────────────────────────────────────────────────────────────
    private func timerPage(now: Date) -> some View {
        let running = timers.timers.filter(\.running)
        let ringing = timers.timers.filter { timers.ringing.contains($0.id) }
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(ringing) { t in
                HStack(spacing: 7) {
                    Image(systemName: "bell.and.waves.left.and.right.fill").font(.sbIcon(10.5)).foregroundStyle(timerColor(t.color))
                    Text(t.label).font(.sb(11.5, weight: .semibold)).nameFit(t.label)
                    Spacer(minLength: 6)
                    Button { timers.stopRinging(t.id) } label: { Label("Stop", systemImage: "bell.slash.fill") }
                        .buttonStyle(.borderedProminent).tint(timerColor(t.color)).sbControlSize(.small).help("Stop the ring")
                    Button { timers.extend(t, by: 60) } label: { Label("1 min", systemImage: "plus") }
                        .sbControlSize(.small).help("Stop the ring and run it a minute more")
                }
            }
            if running.isEmpty && ringing.isEmpty { empty("No timers running") }
            ForEach(running) { t in
                HStack(spacing: 7) {
                    Circle().fill(timerColor(t.color)).frame(width: si(8), height: si(8))
                    Text(t.label).font(.sb(11.5)).nameFit(t.label)
                    Spacer(minLength: 6)
                    Text(clock(t.fireAt.timeIntervalSince(now))).font(.sb(12, weight: .semibold).monospacedDigit())
                    Button { timers.extend(t, by: 60) } label: { Image(systemName: "plus.circle").font(.sbIcon(11)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Add a minute")
                    Button { timers.remove(t) } label: { Image(systemName: "xmark.circle").font(.sbIcon(11)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop it")
                }
                .help("Scroll to add or take away a minute. Middle-click to open it in Timers.")
                // the wheel over a timer moves it a minute a notch; a middle click opens it in the tab
                .scrollSteps("q-timer-" + t.id, card: state.space, stepper: .slider()) { st in timers.nudge(t, minutes: -st) }
                .onMiddleClick("qtimer-" + t.id, space: state.space) { openReveal("timers", "timer-" + t.id) }
            }
            createButton("New timer", tab: "timers")
            if !timers.recent.isEmpty {
                ChipFlow(items: timers.recent.map { r in
                    ChipItem(id: "again-" + r.label + "\(r.seconds)", icon: "arrow.clockwise", text: "\(clock(r.seconds)) \(r.label)",
                             enabled: true, help: "Start \(r.label) again for \(clock(r.seconds))") {
                        timers.add(label: r.label, color: r.color, fireAt: Date().addingTimeInterval(r.seconds))
                    }
                })
            }
        }
    }

    /// The create action on a page: opens the full tab, whose create field takes the keyboard on open.
    private func createButton(_ title: String, tab: String) -> some View {
        Button { openTab(tab) } label: { Label(title, systemImage: "plus") }
            .buttonStyle(.borderedProminent).tint(Color(nsColor: .controlAccentColor)).sbControlSize(.small)
            .help("\(title): opens the panel with the input ready")
    }

    // ── Controls ────────────────────────────────────────────────────────────
    /// Volume and brightness as sliders, Wi-Fi and Bluetooth as switches; the full set is the Controls tab.
    private var controlsPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let v = controls.volume {
                level(icon: controls.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill", value: v,
                      text: controls.muted == true ? "muted" : "\(Int((v * 100).rounded()))%") { controls.setVolume($0) }
            }
            if let b = controls.brightness {
                level(icon: "sun.max.fill", value: b, text: "\(Int((b * 100).rounded()))%") { controls.setBrightness($0) }
            }
            HStack(spacing: 8) {
                if let on = controls.wifiOn {
                    switchItem(on ? "wifi" : "wifi.slash", "Wi-Fi", on, busy: controls.busy.contains("wifi")) { new in
                        if !new && !confirmOff("Turn Wi-Fi off?", "Everything on this Mac that uses the network loses it, including remote sessions.") { return }
                        controls.setWiFi(new)
                    }
                }
                Spacer(minLength: 6)
                if let on = controls.btOn {
                    switchItem("dot.radiowaves.left.and.right", "Bluetooth", on, busy: controls.busy.contains("bluetooth")) { new in
                        if !new && !confirmOff("Turn Bluetooth off?", "A Bluetooth keyboard, mouse or headphones disconnect at once.") { return }
                        controls.setBluetooth(new)
                    }
                }
            }
            if controls.volume == nil && controls.brightness == nil && controls.wifiOn == nil && controls.btOn == nil {
                if controls.loaded { empty("This Mac reports no volume, brightness, Wi-Fi or Bluetooth control to switch.") }
                else { ReadingStatus(state: .loading) }
            }
        }
        .onAppear { controls.load(devices: false) }
    }

    private func switchItem(_ icon: String, _ title: String, _ on: Bool, busy: Bool = false, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.sbIcon(11)).foregroundStyle(.secondary)
            Text(title).font(.sb(11.5))
            Toggle("", isOn: Binding(get: { on }, set: set)).toggleStyle(.switch).sbControlSize(.mini).labelsHidden()
                .disabled(busy)
        }
        .fixedSize()
    }

    /// The same question the Controls tab asks before switching something off that cuts a connection.
    private func confirmOff(_ title: String, _ detail: String) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = detail; a.alertStyle = .warning
        a.addButton(withTitle: "Turn off"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private func level(icon: String, value: Float, text: String, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.sbIcon(11)).foregroundStyle(.secondary).frame(width: si(16))
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1).sbControlSize(.mini)
                .scrollSteps("q-level-" + icon, card: state.space, stepper: .slider()) { st in set(sliderStep(value, by: -st)) }
            Text(text).font(.sb(10.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: sw(38), alignment: .trailing)
        }
    }

    // ── Local models ────────────────────────────────────────────────────────
    /// The Runtime tab's Local models rows as they are, so the keep-loaded menu and buttons work here too.
    private var modelsPage: some View {
        let group = policy.systemGroups.first { $0.title == "Local models" }
        return VStack(alignment: .leading, spacing: 0) {
            if let st = group?.status {
                ReadingStatus(state: st, retry: { policy.requestSystemRefresh() })
            }
            if let g = group, !g.rows.isEmpty {
                ForEach(g.rows) { r in SystemRowView(row: r, store: policy) }
            } else if group?.status == nil {
                // A failed read still makes the group, with its status; none at all means not read yet or no suite.
                if policy.systemReadOnce { empty("No local models suite on this Mac") } else { ReadingStatus(state: .loading) }
            }
        }
    }

    /// A chip names a note by its first few words, ending at a word; the full
    /// title is in the chip's tooltip.
    private func chipLabel(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Untitled" }
        var out = ""
        for w in t.split(separator: " ") {
            if !out.isEmpty && out.count + w.count + 1 > 18 { break }
            out += (out.isEmpty ? "" : " ") + w
        }
        return out
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.sb(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func more(_ n: Int, tab: String) -> some View {
        Button { openTab(tab) } label: { Text("\(n) more in the panel").font(.sb(11)) }.buttonStyle(.link)
    }
}

/// One waiting push or ask, with the same Approve and Cancel the Approvals tab has.
struct QuickNeedRow: View {
    let row: SystemRow
    /// A live session waits on it (not approved already, not left by an ended one).
    var waiting = true
    @State private var busy: String?
    @State private var failed: String?

    /// The symbol beside each answer, so the buttons read at a glance.
    static func icon(for label: String) -> String {
        switch label {
        case "Approve": return "checkmark"
        case "Deny": return "hand.raised.slash"
        case "Cancel": return "xmark"
        default: return "arrow.right"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: waiting ? "hand.raised.fill" : "clock").font(.sbIcon(10))
                    .foregroundStyle(waiting ? Color(nsColor: menuYellow) : .secondary)
                Text(row.label).font(.sb(11.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                ForEach(Array(row.buttons.enumerated()), id: \.offset) { _, b in
                    if case .run(let act) = b.kind {
                        Button {
                            // the same question the tab asks before an action that is easy to regret
                            if let q = b.confirm {
                                let a = NSAlert(); a.messageText = q
                                a.addButton(withTitle: b.label); a.addButton(withTitle: "Cancel")
                                NSApp.activate(ignoringOtherApps: true)
                                guard a.runModal() == .alertFirstButtonReturn else { return }
                            }
                            busy = b.label; failed = nil
                            DispatchQueue.global(qos: .userInitiated).async {
                                let err = act()
                                DispatchQueue.main.async { busy = nil; failed = err }
                            }
                        } label: {
                            Label(b.label, systemImage: b.icon ?? Self.icon(for: b.label)).labelStyle(.titleAndIcon)
                        }
                        .sbControlSize(.small).disabled(busy != nil).help(b.help)
                    }
                }
            }
            if !row.note.isEmpty {
                Text(row.note).font(.sb(10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let f = failed {
                Text(f).font(.sb(10.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An inactive thing as a small chip: icon and a short name; a click makes it active.
struct ChipItem: Identifiable {
    let id: String
    let icon: String
    let text: String
    let enabled: Bool
    let help: String
    /// A middle click: open the thing in its fuller home.
    var middle: (() -> Void)? = nil
    let act: () -> Void
}

/// Chips laid out in rows that wrap, each at its natural width.
struct ChipFlow: View {
    let items: [ChipItem]
    /// The spec's "one or two rows": past that, the last chip says how many more.
    var maxRows = 2
    var overflow: ((Int) -> ChipItem)? = nil

    /// How many chips fit in `maxRows` rows of the card's 296 points, from each
    /// chip's text length (icon, padding and gap included).
    static func fitting(_ texts: [String], rows: Int, width: CGFloat = sw(296), reserve: CGFloat = 0) -> Int {
        var row = 1, x: CGFloat = 0
        for (i, t) in texts.enumerated() {
            let w = sc(34) + CGFloat(t.count) * 6.1 * UIScale.text
            let limit = row == rows ? width - reserve : width
            if x > 0 && x + w > limit { row += 1; x = 0 }
            if row > rows || (row == rows && x + w > limit) { return i }
            x += w + 5
        }
        return texts.count
    }

    private var shown: [ChipItem] {
        let texts = items.map(\.text)
        guard let overflow, Self.fitting(texts, rows: maxRows) < items.count else { return items }
        let n = Self.fitting(texts, rows: maxRows, reserve: sw(74))   // room for the "N more" chip
        return Array(items.prefix(n)) + [overflow(items.count - n)]
    }

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(shown) { c in
                Button(action: c.act) {
                    HStack(spacing: 4) {
                        Image(systemName: c.icon).font(.sbIcon(9.5))
                        Text(c.text).font(.sb(10.5)).lineLimit(1)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(c.enabled ? .primary : .secondary)
                }
                .buttonStyle(.plain).disabled(!c.enabled).help(c.help)
                .modifier(MiddleClickIfAny(id: "chip-" + c.id, act: c.middle))
            }
        }
    }
}

/// Places children left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            // offered the full row, so a child too long for it wraps rather than spills
            let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Registers a middle click only when there is something for it to do.
struct MiddleClickIfAny: ViewModifier {
    let id: String
    let act: (() -> Void)?
    @Environment(\.cardSpace) private var cardSpace
    func body(content: Content) -> some View {
        if let act { content.onMiddleClick(id, space: cardSpace, act) } else { content }
    }
}

/// One bulb on the hover card. On: its name (a click turns it off), an
/// intensity slider the wheel steps, and the percentage at the far right.
/// Off but recently on: a click turns it back on.
struct QuickBulbRow: View {
    let bulb: Bulb
    @ObservedObject var lights: LightsStore
    let lastOn: Date?
    @Environment(\.cardSpace) private var cardSpace
    @State private var dim: Double?
    @State private var send: DispatchWorkItem?
    @State private var settle: DispatchWorkItem?

    private var level: Double { dim ?? Double(bulb.dimming) }
    private var busy: Bool { lights.busy.contains(bulb.mac) }

    var body: some View {
        HStack(spacing: 8) {
            Button { if !busy { lights.set(bulb, ["state=\(bulb.on ? "off" : "on")"]) } } label: {
                HStack(spacing: 7) {
                    Image(systemName: bulb.on ? "lightbulb.fill" : "lightbulb").font(.sbIcon(11))
                        .foregroundStyle(bulb.on ? Color.yellow : Color.secondary).frame(width: si(14))
                    Text(bulb.title).font(.sb(11.5)).fixedSize(horizontal: false, vertical: true)
                    if !bulb.on {
                        Text(lastOn.map { "off · on \(relative($0, now: Date()))" } ?? "off")
                            .font(.sb(10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(bulb.on ? "Turn \(bulb.title) off. Middle-click to open it in Home." : "Turn \(bulb.title) on. Middle-click to open it in Home.")
            if bulb.on {
                Slider(value: Binding(get: { level }, set: { change($0) }), in: 10...100).sbControlSize(.mini)
                    .frame(width: sc(110))
                    .scrollSteps("q-bulb-" + bulb.mac, card: cardSpace, stepper: .slider()) { st in change(level - Double(st) * 5) }
                Text("\(Int(level.rounded()))%").font(.sb(10.5).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: sw(32), alignment: .trailing)
            }
        }
        // a send in flight blocks a second on/off click, never the slider, so a wheel gesture keeps every notch
        .disabled(!bulb.reachable)
        .opacity(bulb.reachable ? 1 : 0.55)
    }

    /// Shows the new level at once and sends it once the slider or wheel rests.
    private func change(_ v: Double) {
        let v = min(100, max(10, v.rounded()))
        dim = v
        send?.cancel()
        settle?.cancel()
        let w = DispatchWorkItem { [lights, bulb] in
            lights.set(bulb, ["dimming=\(Int(v))"])
            // hand the slider back to the bulb's own report once the wheel has rested, not mid-gesture
            let back = DispatchWorkItem { dim = nil }
            settle = back
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: back)
        }
        send = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}
