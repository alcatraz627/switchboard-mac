// QuickPages.swift
// The pages the hover card cycles through when the owner scrolls over the
// menu-bar icon: Home (the usual lines plus a row of status chips), then
// Limits, Approvals, Bulbs and Pinned notes. Each page lists what is active
// at full width and squeezes the rest into small chips; a chip makes its
// thing active, and every page has a button that opens its full tab.

import AppKit
import SwiftUI

enum QuickPage: String, CaseIterable {
    case home, limits, approvals, bulbs, notes

    var title: String {
        switch self {
        case .home: return "Now"
        case .limits: return "Limits"
        case .approvals: return "Approvals"
        case .bulbs: return "Bulbs"
        case .notes: return "Pinned notes"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .limits: return Icons.tab["usage"] ?? "gauge"
        case .approvals: return Icons.tab["approvals"] ?? "hand.raised"
        case .bulbs: return "lightbulb"
        case .notes: return "pin"
        }
    }
    /// The panel tab that shows this page in full.
    var tab: String? {
        switch self {
        case .home: return nil
        case .limits: return "usage"
        case .approvals: return "approvals"
        case .bulbs: return "home"
        case .notes: return "notes"
        }
    }
}

/// Turns scroll-wheel movement into page turns: one page per push of the
/// wheel or swipe, never a run of pages from a single trackpad flick.
struct QuickCycle {
    /// Where a trackpad or Magic Mouse gesture is; a mouse wheel has none.
    enum Phase { case none, began, changed, ended }

    /// The pages in the owner's order; scrolling and number keys walk this list.
    var pages: [QuickPage] = QuickPage.allCases
    private(set) var page: QuickPage = .home
    private var acc: CGFloat = 0
    private var lastTurn: TimeInterval = -.infinity
    private var lastEvent: TimeInterval = -.infinity
    private var turnedThisGesture = false
    /// Points of travel a swipe needs before it turns a page.
    static let threshold: CGFloat = 6
    /// The shortest gap between two wheel turns, so a fast spin steps rather than races.
    static let wheelPause: TimeInterval = 0.2
    /// Travel older than this belongs to an earlier gesture and is forgotten.
    static let staleAfter: TimeInterval = 0.5

    /// One scroll event; true when the page changed. Content-style direction:
    /// scrolling the way that moves a list down goes forward. A swipe turns
    /// at most one page however long it runs; each wheel notch turns one.
    mutating func scroll(delta: CGFloat, precise: Bool, phase: Phase, momentum: Bool, at t: TimeInterval) -> Bool {
        if momentum { return false }                 // inertia after the finger lifts turns nothing
        guard delta != 0 || phase != .none else { return false }
        if !precise {
            guard delta != 0, t - lastTurn >= Self.wheelPause else { return false }
            turn(delta < 0 ? 1 : -1, at: t)
            return true
        }
        if phase == .began || t - lastEvent > Self.staleAfter { acc = 0; turnedThisGesture = false }
        lastEvent = t
        if phase == .ended { acc = 0; turnedThisGesture = false; return false }
        guard !turnedThisGesture else { return false }
        acc += delta
        guard abs(acc) >= Self.threshold else { return false }
        turn(acc < 0 ? 1 : -1, at: t)
        turnedThisGesture = true
        return true
    }

    mutating func turn(_ by: Int, at t: TimeInterval) {
        let all = pages.isEmpty ? QuickPage.allCases : pages
        let i = all.firstIndex(of: page) ?? 0
        page = all[(i + by % all.count + all.count) % all.count]
        lastTurn = t
        acc = 0
    }

    /// Forgets any half-made gesture; the page stays where it was.
    mutating func forgetGesture() { acc = 0; lastTurn = -.infinity; lastEvent = -.infinity; turnedThisGesture = false }
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
    check("back from the first page wraps to the last",
          r.scroll(delta: 1, precise: false, phase: .none, momentum: false, at: 0) && r.page == .notes, r.page.rawValue)
    check("forward from the last wraps to the first",
          r.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 1) && r.page == .home, r.page.rawValue)
    var d = QuickCycle()
    for (i, want) in [QuickPage.limits, .approvals, .bulbs, .notes, .home].enumerated() {
        _ = d.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: Double(i))
        if d.page != want { check("pages come in order", false, d.page.rawValue); return lines.joined(separator: "\n") }
    }
    check("pages come in order: now, limits, approvals, bulbs, pinned notes", true)

    // Where the card reopens: the page it last showed, or the first when that page is gone.
    var m = QuickCycle()
    m.show(.bulbs); m.forgetGesture()
    check("a new hover keeps the page the last one showed", m.page == .bulbs, m.page.rawValue)
    m.pages = [.limits, .notes, .home]
    m.show(.bulbs)
    check("a page no longer in the list falls back to the first", m.page == .limits, m.page.rawValue)
    _ = m.scroll(delta: -1, precise: false, phase: .none, momentum: false, at: 0)
    check("scrolling follows the owner's order", m.page == .notes, m.page.rawValue)

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
    check("limits are Claude 5h, Claude 7d, Codex 7d", bars == ["sparkle 5h 10", "sparkle 7d 20", "terminal 7d 30"], bars.joined(separator: ", "))
    let many = Array(repeating: "Release work", count: 30)
    let fit = ChipFlow.fitting(many, rows: 2)
    check("thirty chips are cut to what two rows hold", fit > 2 && fit < 12, "\(fit)")
    check("a few short chips all fit", ChipFlow.fitting(["a", "b", "c"], rows: 2) == 3)
    return lines.joined(separator: "\n")
}

/// What the card shows and which page it is on; the view follows it.
final class QuickState: ObservableObject {
    @Published var page: QuickPage = .home
    /// The pages in the owner's order.
    @Published var pages: [QuickPage] = QuickPage.allCases
    /// How far down the card the title bar ends, measured when it draws;
    /// scrolling above this line turns pages.
    var headerBottom: CGFloat = 34
    @Published var homeLines: [HoverLine] = []
    @Published var chips: [StatusChip] = []
}

/// A small chip on the Now page for something that needs the owner: its own
/// colour and icon, a tooltip, and a click that opens the page that shows it.
struct StatusChip: Identifiable {
    let id: String
    let icon: String
    let text: String
    let tint: Color
    let help: String
    let opens: QuickPage?
    let tab: String?
}

/// The hover card: a header with the page's name and dots for every page,
/// then the page itself.
struct QuickCard: View {
    @ObservedObject var state: QuickState
    @ObservedObject var policy: PolicyStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var lights: LightsStore
    @ObservedObject var notes: NotesStore
    let openTab: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .background(GeometryReader { g in
                    Color.clear.onAppear { state.headerBottom = g.frame(in: .named("quickCard")).maxY + 5 }
                })
            Divider().padding(.horizontal, -12)
            switch state.page {
            case .home: home
            case .limits: limits
            case .approvals: approvals
            case .bulbs: bulbs
            case .notes: pinned
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(GlassBackground())
        .coordinateSpace(name: "quickCard")
    }

    /// One pill per page, the panel's tab grammar in small: an icon each, the
    /// current one also named, a click or its number key goes there.
    private var header: some View {
        HStack(spacing: 4) {
            ForEach(Array(state.pages.enumerated()), id: \.element) { i, p in
                let on = p == state.page
                Button { state.page = p } label: {
                    HStack(spacing: 4) {
                        Image(systemName: p.icon).font(.system(size: 10, weight: .semibold))
                        if on { Text(p.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize() }
                    }
                    .padding(.horizontal, on ? 8 : 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(on ? 0.16 : 0.06)))
                    .foregroundStyle(on ? .primary : .secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).help("\(p.title) (\(i + 1))")
            }
            Spacer(minLength: 4)
            if let tab = state.page.tab {
                Button { openTab(tab) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open \(state.page.title) in the panel")
            }
        }
    }

    // ── Now ─────────────────────────────────────────────────────────────────
    private var home: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.chips.isEmpty {
                // chips keep their natural width; if four ever would not fit, fewer show, never a cut one
                ViewThatFits(in: .horizontal) {
                    chipRow(3); chipRow(2); chipRow(1)
                }
            }
            HoverLinesView(lines: state.homeLines)
            if state.homeLines.isEmpty && state.chips.isEmpty {
                Text("Nothing needs you").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
    /// Three is the count that always fits the 320-point card at its widest
    /// wording (measured: a fourth spills); chips come most urgent first.
    static let maxChips = 3

    private func chipRow(_ n: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(state.chips.prefix(min(n, QuickCard.maxChips))) { c in
                Button {
                    if let p = c.opens { state.page = p } else if let t = c.tab { openTab(t) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: c.icon).font(.system(size: 9.5, weight: .semibold))
                        Text(c.text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(c.tint.opacity(0.2)))
                    .foregroundStyle(c.tint)
                    .fixedSize()
                }
                .buttonStyle(.plain).help(c.help)
            }
        }
        .fixedSize()
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
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(rows) { r in QuickNeedRow(row: r, waiting: title == "Pushes" || title == "Policy asks") }
            }
            if total > 5 { more(total - 5, tab: "approvals") }
        }
    }

    // ── Bulbs ───────────────────────────────────────────────────────────────
    private var bulbs: some View {
        let on = lights.bulbs.filter { $0.on && $0.reachable }
        let off = lights.bulbs.filter { !($0.on && $0.reachable) }
        return VStack(alignment: .leading, spacing: 7) {
            if lights.bulbs.isEmpty { empty(lights.discovering ? "Looking for bulbs…" : "No bulbs found") }
            ForEach(on) { b in
                HStack(spacing: 7) {
                    Image(systemName: "lightbulb.fill").font(.system(size: 11)).foregroundStyle(.yellow)
                    Text(b.title).font(.system(size: 11.5))
                    Text("\(b.dimming)%").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { lights.set(b, ["state=off"]) } label: { Image(systemName: "power").font(.system(size: 11)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Turn \(b.title) off")
                        .disabled(lights.busy.contains(b.mac))
                }
            }
            if !off.isEmpty {
                ChipFlow(items: off.map { b in
                    ChipItem(id: b.mac, icon: "lightbulb", text: b.title, enabled: b.reachable && !lights.busy.contains(b.mac),
                             help: b.reachable ? "Turn \(b.title) on" : "\(b.title) is not answering") { lights.set(b, ["state=on"]) }
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
        let live = notes.live
        let pins = live.filter(\.pinned)
        let rest = live.filter { !$0.pinned }
        return VStack(alignment: .leading, spacing: 7) {
            if pins.isEmpty { empty("No pinned notes. Pin one below or in the Notes tab.") }
            ForEach(pins) { n in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Text(n.title).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(n.content, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 10.5)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Copy the note")
                    Button { var m = n; m.pinned = false; notes.update(m) } label: {
                        Image(systemName: "pin.slash").font(.system(size: 10.5))
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Unpin")
                }
            }
            if !rest.isEmpty {
                ChipFlow(items: rest.map { n in
                    ChipItem(id: n.id, icon: "pin", text: chipLabel(n.title), enabled: true, help: "Pin \u{201C}\(n.title)\u{201D}") {
                        var m = n; m.pinned = true; notes.update(m)
                    }
                }, overflow: { more in
                    ChipItem(id: "more", icon: "ellipsis", text: "\(more) more", enabled: true, help: "Open the Notes tab") { openTab("notes") }
                })
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
        Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func more(_ n: Int, tab: String) -> some View {
        Button { openTab(tab) } label: { Text("\(n) more in the panel").font(.system(size: 11)) }.buttonStyle(.link)
    }
}

/// One waiting push or ask, with the same Approve and Cancel the Approvals tab has.
struct QuickNeedRow: View {
    let row: SystemRow
    /// A live session waits on it (not approved already, not left by an ended one).
    var waiting = true
    @State private var busy: String?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: waiting ? "hand.raised.fill" : "clock").font(.system(size: 10))
                    .foregroundStyle(waiting ? Color(nsColor: menuYellow) : .secondary)
                Text(row.label).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                ForEach(Array(row.buttons.enumerated()), id: \.offset) { _, b in
                    if case .run(let act) = b.kind {
                        Button(b.label) {
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
                        }
                        .controlSize(.small).disabled(busy != nil).help(b.help)
                    }
                }
            }
            if !row.note.isEmpty {
                Text(row.note).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let f = failed {
                Text(f).font(.system(size: 10.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
    static func fitting(_ texts: [String], rows: Int, width: CGFloat = 296, reserve: CGFloat = 0) -> Int {
        var row = 1, x: CGFloat = 0
        for (i, t) in texts.enumerated() {
            let w = 34 + CGFloat(t.count) * 6.1
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
        let n = Self.fitting(texts, rows: maxRows, reserve: 74)   // room for the "N more" chip
        return Array(items.prefix(n)) + [overflow(items.count - n)]
    }

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(shown) { c in
                Button(action: c.act) {
                    HStack(spacing: 4) {
                        Image(systemName: c.icon).font(.system(size: 9.5))
                        Text(c.text).font(.system(size: 10.5)).lineLimit(1)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(c.enabled ? .primary : .secondary)
                }
                .buttonStyle(.plain).disabled(!c.enabled).help(c.help)
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
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
