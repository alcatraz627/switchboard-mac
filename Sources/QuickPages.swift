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
    private(set) var page: QuickPage = .home
    private var acc: CGFloat = 0
    private var lastTurn: TimeInterval = -.infinity
    /// Points of travel that turn a page, and the pause before the next turn.
    static let threshold: CGFloat = 6
    static let cooldown: TimeInterval = 0.35

    /// One scroll event. `down` is the owner's direction after natural
    /// scrolling is undone: down (or a swipe up on a trackpad) goes forward.
    /// Returns true when the page changed.
    mutating func scroll(delta: CGFloat, at t: TimeInterval, momentum: Bool) -> Bool {
        if momentum { return false }                 // inertia after the finger lifts turns nothing
        if t - lastTurn < Self.cooldown { acc = 0; return false }
        acc += delta
        guard abs(acc) >= Self.threshold else { return false }
        turn(acc < 0 ? 1 : -1, at: t)
        return true
    }

    mutating func turn(_ by: Int, at t: TimeInterval) {
        let all = QuickPage.allCases
        let i = all.firstIndex(of: page) ?? 0
        page = all[(i + by % all.count + all.count) % all.count]
        lastTurn = t
        acc = 0
    }

    mutating func reset() { page = .home; acc = 0; lastTurn = -.infinity }
    mutating func show(_ p: QuickPage) { page = p; acc = 0 }
}

/// Checks the page-turning rules without a mouse.
func probeQuickCycle() -> String {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    var c = QuickCycle()
    check("starts on the usual card", c.page == .home)
    check("a nudge smaller than a step turns nothing", !c.scroll(delta: -2, at: 0, momentum: false) && c.page == .home)
    check("enough travel down turns forward", c.scroll(delta: -5, at: 0.01, momentum: false) && c.page == .limits, c.page.rawValue)
    for i in 0..<10 { _ = c.scroll(delta: -3, at: 0.02 + Double(i) * 0.02, momentum: false) }
    check("one flick turns one page, not several", c.page == .limits, c.page.rawValue)
    check("inertia after the finger lifts turns nothing", !c.scroll(delta: -40, at: 1.0, momentum: true) && c.page == .limits)
    check("up goes back", c.scroll(delta: 8, at: 1.0, momentum: false) && c.page == .home, c.page.rawValue)
    check("back from the first page wraps to the last", c.scroll(delta: 8, at: 2.0, momentum: false) && c.page == .notes, c.page.rawValue)
    check("forward from the last wraps to the first", c.scroll(delta: -8, at: 3.0, momentum: false) && c.page == .home, c.page.rawValue)
    var d = QuickCycle()
    for (i, want) in [QuickPage.limits, .approvals, .bulbs, .notes, .home].enumerated() {
        _ = d.scroll(delta: -10, at: Double(i), momentum: false)
        if d.page != want { check("pages come in order", false, d.page.rawValue); return lines.joined(separator: "\n") }
    }
    check("pages come in order: now, limits, approvals, bulbs, pinned notes", true)
    return lines.joined(separator: "\n")
}

/// What the card shows and which page it is on; the view follows it.
final class QuickState: ObservableObject {
    @Published var page: QuickPage = .home
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
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.page.icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(state.page.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            // one dot per page; the lit one is where you are, and a click goes there
            HStack(spacing: 4) {
                ForEach(QuickPage.allCases, id: \.self) { p in
                    Circle().fill(p == state.page ? Color.primary.opacity(0.85) : Color.primary.opacity(0.25))
                        .frame(width: 5, height: 5)
                        .onTapGesture { state.page = p }
                        .help(p.title)
                }
            }
            .help("Scroll over the menu-bar icon to move between pages")
            if let tab = state.page.tab {
                Button { openTab(tab) } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open the full \(state.page.title) tab")
            }
        }
    }

    // ── Now ─────────────────────────────────────────────────────────────────
    private var home: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.chips.isEmpty {
                // chips keep their natural width; the count is capped so the row always fits
                HStack(spacing: 5) {
                    ForEach(state.chips.prefix(QuickCard.maxChips)) { c in
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
                    Spacer(minLength: 0)
                }
            }
            HoverLinesView(lines: state.homeLines)
            if state.homeLines.isEmpty && state.chips.isEmpty {
                Text("Nothing needs you").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
    static let maxChips = 4

    // ── Limits ──────────────────────────────────────────────────────────────
    private var limits: some View {
        let bars: [HoverLine] = (usage.claude.map { ("Claude", $0) } + usage.codex.map { ("Codex", $0) }).map { who, w in
            .bar(label: shortLabel(who, w), pct: w.pct,
                 color: w.pct >= usage.dangerPct ? .red : w.pct >= usage.warnPct ? .orange : .green,
                 resets: w.resetsAt.map { $0 > Date() ? "in " + countdownText(to: $0, now: Date()) : "" } ?? "")
        }
        return Group {
            if bars.isEmpty { empty("No limits read yet") } else { HoverLinesView(lines: bars, labelWidth: 64) }
        }
    }
    private func shortLabel(_ who: String, _ w: UsageWindow) -> String {
        let span = w.id == "five_hour" ? "5h" : w.id == "seven_day" ? "week" : w.label
        return who == "Claude" ? span : "Codex " + span
    }

    // ── Approvals ───────────────────────────────────────────────────────────
    private var approvals: some View {
        let rows = policy.needGroups.flatMap(\.rows).filter { !$0.buttons.isEmpty }
        return VStack(alignment: .leading, spacing: 7) {
            if rows.isEmpty { empty("Nothing waits on you") }
            ForEach(rows.prefix(5)) { r in QuickNeedRow(row: r) }
            if rows.count > 5 { more(rows.count - 5, tab: "approvals") }
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
                ChipFlow(items: rest.prefix(8).map { n in
                    ChipItem(id: n.id, icon: "pin", text: n.title, enabled: true, help: "Pin \u{201C}\(n.title)\u{201D}") {
                        var m = n; m.pinned = true; notes.update(m)
                    }
                })
            }
        }
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
    @State private var busy: String?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Color(nsColor: menuYellow))
                Text(row.label).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                ForEach(Array(row.buttons.enumerated()), id: \.offset) { _, b in
                    if case .run(let act) = b.kind {
                        Button(b.label) {
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

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items) { c in
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
