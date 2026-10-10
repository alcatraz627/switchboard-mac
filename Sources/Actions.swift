// Actions.swift
// Every key the panel answers, written down once. The palette (⇧⌘P), the hint
// strip (hold ⌘, or the ⓘ in the header) and the probe all read this one table,
// so a key can never be bound without being findable, and the hints can never
// disagree with the palette. Rules: docs/plans/20261010-keyboard-convention.md

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One thing a key does on one surface. `run` is nil for a key that only moves
/// the keyboard (↑/↓, Escape): it is listed so the owner can find it, but the
/// palette has nothing to run for it. `short` is the hint strip's wording.
struct KeyAction: Identifiable, Equatable {
    static func == (a: KeyAction, b: KeyAction) -> Bool { a.id == b.id }
    let id: String
    let title: String
    let short: String
    let key: String
    /// "panel" for a key that works on every tab, else the tab's id.
    let surface: String
    /// Where the keyboard has to be: "anywhere", "tab", "row", "open", "field".
    let depth: String
    var run: (() -> Void)? = nil
}

/// The table. Keys that move are listed without a runner; keys that act get
/// one from the panel at launch (`ActionRegistry.runners`).
enum KeyTable {
    static func a(_ id: String, _ title: String, _ short: String, _ key: String, _ surface: String = "panel", _ depth: String = "anywhere") -> KeyAction {
        KeyAction(id: id, title: title, short: short, key: key, surface: surface, depth: depth)
    }

    /// Works on every tab, at every depth.
    static let panel: [KeyAction] = [
        a("panel.leader", "Open Switchboard, then show the jump letters, then close", "Open · jump", "⌥Space or ⌘⌘"),
        a("panel.palette", "Find any action or place", "Find anything", "⇧⌘P"),
        a("panel.goto", "Go to a tab, a note or a timer", "Go to…", "⌘J"),
        a("panel.keys", "The keys that work right here", "Keys here", "⌘/ · hold ⌘"),
        a("panel.space", "Pick a space", "Space", "⌘1–5"),
        a("panel.tab.next", "Next tab in this space", "Next tab", "⌘⌥→"),
        a("panel.tab.prev", "Previous tab in this space", "Previous tab", "⌘⌥←"),
        a("panel.tab.walk", "Walk every tab, Approvals and Settings included", "Walk tabs", "⌃Tab"),
        a("panel.zone", "Next zone: spaces and header buttons, tabs, the box above the list, the rows", "Next zone", "Tab"),
        a("panel.hints", "Keep the key hints up on every tab", "Hints stay", "ⓘ"),
        a("panel.pinopen", "Keep the panel open until you close it", "Pin open", "⌘P"),
        a("panel.pin", "Pin this tab to the desktop", "Pin to desk", "⌘D"),
        a("panel.reload", "Reload this tab", "Reload", "⌘R"),
        a("panel.search", "Jump to the search box", "Search box", "⌘L"),
        a("panel.settings", "Open Settings", "Settings", "⌘,"),
        a("panel.close", "Step out, then close the panel and go back", "Out · close · back", "Esc"),
    ]

    /// Any tab whose rows take keys by being rows (Keys.swift, KeyRows).
    static func generic(_ tab: String) -> [KeyAction] { [
        a("\(tab).row.move", "Move between rows", "Rows", "↑/↓", tab, "tab"),
        a("\(tab).row.open", "Do what a click on the row does", "Click", "Return", tab, "row"),
        a("\(tab).row.flip", "Flip the row's switch", "Flip", "Space", tab, "row"),
        a("\(tab).row.step", "Step a slider, or open and close a row with children", "Step · open", "←/→", tab, "row"),
        a("\(tab).row.letgo", "Let go of the row", "Let go", "Esc", tab, "row"),
    ] }

    static let notes: [KeyAction] = [
        a("notes.compose.type", "Write the new note (⇧Return for the body)", "New note", "type", "notes", "tab"),
        a("notes.compose.save", "Save the new note and keep writing in it", "Save", "⌘Return", "notes", "field"),
        a("notes.compose.leave", "Leave the new note, draft kept", "Leave, keep draft", "Esc", "notes", "field"),
        a("notes.list.move", "Move between notes", "Notes", "↑/↓", "notes", "tab"),
        a("notes.list.filter", "Along the colour filter; Space toggles a colour", "Colour filter", "←/→", "notes", "tab"),
        a("notes.list.search", "Search", "Search", "/", "notes", "tab"),
        a("notes.row.open", "Open the note to read", "Open", "→ · Return", "notes", "row"),
        a("notes.row.pin", "Pin or unpin", "Pin", "P", "notes", "row"),
        a("notes.row.copy", "Copy title and body", "Copy", "C", "notes", "row"),
        a("notes.row.color", "Set a colour (0 clears)", "Colour", "1–8", "notes", "row"),
        a("notes.row.delete", "Delete, with a confirm", "Delete", "⌫", "notes", "row"),
        a("notes.open.parts", "Move between title, body, tags, expiry, reminder, history, colour, pin, copy, delete", "Parts", "↑/↓ · Tab", "notes", "open"),
        a("notes.open.edit", "Start typing in the chosen part", "Edit part", "→ · Return", "notes", "open"),
        a("notes.open.copyall", "Copy title and body together", "Copy all", "⇧⌘C", "notes", "open"),
        a("notes.open.close", "Close the note", "Close", "← · Esc", "notes", "open"),
        a("notes.field.stop", "Stop typing and save; the note stays open", "Stop · save", "Esc", "notes", "field"),
        a("notes.field.save", "Save now and keep typing", "Save, keep typing", "⌘Return", "notes", "field"),
    ]

    static let timers: [KeyAction] = [
        a("timers.field.leave", "Leave the new timer for the list", "To the list", "Esc", "timers", "field"),
        a("timers.list.move", "Move between timers (↑ from the first goes back to the box)", "Timers", "↑/↓", "timers", "tab"),
        a("timers.row.rename", "Rename", "Rename", "Return", "timers", "row"),
        a("timers.row.extend", "Add a minute", "+1 min", "+", "timers", "row"),
        a("timers.row.clear", "Clear the timer", "Clear", "⌫", "timers", "row"),
    ]

    static let home: [KeyAction] = [
        a("home.list.move", "Move between bulbs", "Bulbs", "↑/↓", "home", "tab"),
        a("home.row.switch", "Switch the bulb on or off", "On · off", "Space", "home", "row"),
        a("home.row.dim", "Brightness", "Brightness", "←/→", "home", "row"),
        a("home.row.warm", "Warmth", "Warmth", "⇧←/⇧→", "home", "row"),
        a("home.row.strip", "Open the colour strip", "Colours", "Return", "home", "row"),
        a("home.row.color", "Pick a colour from the open strip", "Pick colour", "1–8", "home", "row"),
    ]

    static let approvals: [KeyAction] = [
        a("approvals.row.move", "Move between requests", "Requests", "↑/↓", "approvals", "tab"),
        a("approvals.row.open", "Open the request", "Open", "Return", "approvals", "row"),
        a("approvals.open.allow", "Allow the open request", "Allow", "⌘Return", "approvals", "open"),
        a("approvals.open.deny", "Deny the open request", "Deny", "⌫", "approvals", "open"),
        a("approvals.open.back", "Close the panel; focus goes back to the app you came from", "Close · back", "Esc", "approvals", "open"),
    ]

    static let controls: [KeyAction] = [
        a("controls.row.move", "Move between sound, display, Wi-Fi, Bluetooth and its devices", "Rows", "↑/↓", "controls", "tab"),
        a("controls.row.flip", "Mute, Wi-Fi or Bluetooth on and off, connect or disconnect a device", "Flip", "Space", "controls", "row"),
        a("controls.row.step", "Volume or brightness, 5% a step", "Level", "←/→", "controls", "row"),
        a("controls.row.letgo", "Let go of the row", "Let go", "Esc", "controls", "row"),
    ]

    /// Every key that works on a tab: the panel's, then the tab's own.
    static func actions(for tab: String) -> [KeyAction] {
        let own: [KeyAction]
        switch tab {
        case "notes": own = notes
        case "timers": own = timers
        case "home": own = home
        case "approvals": own = approvals
        case "controls": own = controls
        default: own = generic(tab)
        }
        return panel + own
    }
}

/// What the palette is open for.
enum PaletteMode: Equatable {
    /// Every action and every place.
    case all
    /// Places only: tabs, notes, timers.
    case goTo
    /// The keys on this tab, at the depth the keyboard is at.
    case keys
}

/// The live side of the table: the palette's state, the ⌘-held flag, the
/// runners the panel hands in, and the places the owner can jump to.
final class ActionRegistry: ObservableObject {
    static let shared = ActionRegistry()
    static let pinnedKey = "switchboard.hintsPinned"

    @Published var palette: PaletteMode?
    @Published var query = ""
    @Published var chosen = 0
    /// ⌘ has been held long enough to ask for the hints.
    @Published var hints = false
    /// The ⓘ in the header: hints stay up on every tab until it is clicked again.
    @Published var hintsPinned = UserDefaults.standard.bool(forKey: ActionRegistry.pinnedKey) {
        didSet { UserDefaults.standard.set(hintsPinned, forKey: Self.pinnedKey) }
    }
    var showHints: Bool { hints || hintsPinned }

    /// By action id. The panel sets these at launch; a tab may add its own.
    var runners: [String: () -> Void] = [:]
    /// Places to jump to, read when the palette opens: id, title, run.
    var places: () -> [KeyAction] = { [] }
    /// The tab the panel shows, and the depth the keyboard is at on it.
    var currentTab: () -> String = { "agents" }
    var currentDepth: () -> String = { "tab" }

    func open(_ mode: PaletteMode) {
        query = ""
        chosen = 0
        palette = mode
    }
    func close() { palette = nil; query = "" }

    /// The rows the palette shows for its mode and the typed query, in order.
    func rows() -> [KeyAction] {
        guard let mode = palette else { return [] }
        let tab = currentTab()
        var all: [KeyAction]
        switch mode {
        case .goTo: all = places()
        case .keys: all = hintRows()
        case .all: all = places() + KeyTable.actions(for: tab).map(bound)
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        let words = q.split(separator: " ").map(String.init)
        return all.filter { r in
            let hay = (r.title + " " + r.key + " " + r.surface).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// The keys live where the keyboard is: typing shows the typing keys, an
    /// open note its keys, and the list shows the list and row keys together
    /// since a row is one ↓ away. The tab's own keys first, then the panel's.
    func hintRows() -> [KeyAction] {
        let tab = currentTab(), depth = currentDepth()
        let own = KeyTable.actions(for: tab).filter { $0.surface != "panel" }
        let depths: Set<String> = depth == "field" ? ["field"] : depth == "open" ? ["open"] : ["tab", "row"]
        let here = own.filter { depths.contains($0.depth) }
        let panelKeys = KeyTable.panel.filter { ["panel.palette", "panel.goto", "panel.tab.next", "panel.space", "panel.zone", "panel.close"].contains($0.id) }
        return (here.isEmpty ? own : here) + panelKeys
    }

    /// The action with its runner attached, when the panel gave it one.
    private func bound(_ x: KeyAction) -> KeyAction {
        var r = x
        r.run = runners[x.id]
        return r
    }

    /// Return on the chosen row: run it, or say which key does it.
    func runChosen() {
        let list = rows()
        guard list.indices.contains(chosen) else { close(); return }
        let r = list[chosen]
        close()
        if let run = r.run { run() } else { Toast.shared.show("\(r.key): \(r.title)") }
    }

    /// The palette's own keys. True when the key was used.
    func handle(_ e: NSEvent) -> Bool {
        guard palette != nil else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(e.keyCode) {
        case kVK_Escape: close(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter: runChosen(); return true
        case kVK_DownArrow where mods.isEmpty: chosen = min(max(0, rows().count - 1), chosen + 1); return true
        case kVK_UpArrow where mods.isEmpty: chosen = max(0, chosen - 1); return true
        case kVK_Tab: return true
        default: return false   // typing goes to the search box
        }
    }
}

/// Tells "⌘ held on its own for a while" from ⌘ pressed for a shortcut. The
/// hints show while it stays down and go the moment anything else happens.
final class CommandHold {
    /// Short enough to feel instant, long enough that ⌘C never flashes the strip.
    static let hold: TimeInterval = 0.2
    private var timer: Timer?

    func feed(_ e: NSEvent) {
        let reg = ActionRegistry.shared
        if e.type == .flagsChanged, e.modifierFlags.intersection([.command, .shift, .option, .control, .function]) == .command {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { _ in reg.hints = true }
            return
        }
        timer?.invalidate(); timer = nil
        if reg.hints { reg.hints = false }
    }
}

// ── Views ───────────────────────────────────────────────────────────────────

/// The colour of a key: the crimson that inline code wears, not alarm red.
let keyTint = Color(red: 0.80, green: 0.18, blue: 0.33)

/// A key, drawn as a small pill.
struct KeyPill: View {
    let text: String
    var body: some View {
        Text(text).font(.sb(10, weight: .semibold).monospaced())
            .foregroundStyle(keyTint)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(keyTint.opacity(0.14)))
            .lineLimit(1).fixedSize()
    }
}

/// Hold ⌘, or pin the ⓘ: the keys that work where the keyboard is, two
/// columns, five rows, nothing wrapping.
struct HintStrip: View {
    @ObservedObject private var reg = ActionRegistry.shared
    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(reg.hintRows().prefix(10))) { r in
                HStack(spacing: 5) {
                    KeyPill(text: r.key)
                    Text(r.short).font(.sb(10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .accessibilityIdentifier("hint-strip")
    }
}

/// ⇧⌘P: a search box over every action and place; ↑/↓ choose, Return runs.
/// Drawn over the content, so the panel keeps its height while it is open.
struct PaletteView: View {
    @ObservedObject private var reg = ActionRegistry.shared
    @FocusState private var typing: Bool

    private var prompt: String {
        switch reg.palette {
        case .goTo: return "Go to…"
        case .keys: return "Keys here…"
        default: return "Do or go to…"
        }
    }

    var body: some View {
        let rows = reg.rows()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "command").font(.sbIcon(11)).foregroundStyle(keyTint)
                TextField(prompt, text: $reg.query)
                    .textFieldStyle(.plain).font(PT.label)
                    .focused($typing)
                    .onChange(of: reg.query) { _ in reg.chosen = 0 }
                KeyPill(text: "Esc")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            if rows.isEmpty {
                Text("Nothing matches").font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(rows.prefix(40).enumerated()), id: \.element.id) { i, r in
                                HStack(spacing: 6) {
                                    Text(r.title).font(PT.label).lineLimit(1)
                                    Spacer(minLength: 6)
                                    if r.surface != "panel", r.surface != "place" {
                                        Text(r.surface).font(.sb(10)).foregroundStyle(.tertiary)
                                    }
                                    KeyPill(text: r.key)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == reg.chosen ? keyTint.opacity(0.16) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { reg.chosen = i; reg.runChosen() }
                                .id(r.id)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: reg.chosen) { i in
                        if rows.indices.contains(i) { withAnimation(Motion.fast) { proxy.scrollTo(rows[i].id) } }
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(keyTint.opacity(0.45), lineWidth: 1))
        .onAppear { typing = true }
        .accessibilityIdentifier("palette")
    }
}

// ── Probe ───────────────────────────────────────────────────────────────────

/// The table and the palette, with no window.
func probeActions() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let allTabs = Visibility.spaces.flatMap(\.tabs) + ["approvals", "settings"]
    check("every tab has keys listed", allTabs.allSatisfy { t in KeyTable.actions(for: t).contains { $0.surface == t } })
    let ids = KeyTable.panel.map(\.id) + allTabs.flatMap { t in KeyTable.actions(for: t).filter { $0.surface == t }.map(\.id) }
    check("no two actions share an id", Set(ids).count == ids.count)
    check("every notes key in the rules is in the table",
          ["P", "C", "⌫", "/", "⇧⌘C", "⌘Return"].allSatisfy { k in KeyTable.notes.contains { $0.key.contains(k) } })
    check("every panel-wide key the router answers is in the table",
          ["⌘⌘", "⌃Tab", "⌘1–5", "⌘⌥→", "⇧⌘P", "⌘J", "⌘P", "Tab"].allSatisfy { k in KeyTable.panel.contains { $0.key.contains(k) } })
    check("every short label fits a half-width column", KeyTable.actions(for: "notes").allSatisfy { $0.short.count <= 18 })

    let reg = ActionRegistry.shared
    var ran: [String] = []
    reg.runners = ["panel.reload": { ran.append("reload") }]
    reg.places = { [KeyAction(id: "place.notes", title: "Go to Notes", short: "Notes", key: "N", surface: "place", depth: "anywhere", run: { ran.append("notes") })] }
    reg.currentTab = { "usage" }
    reg.open(.all)
    check("the palette lists places and the tab's keys", reg.rows().contains { $0.id == "place.notes" } && reg.rows().contains { $0.id == "usage.row.move" })
    reg.query = "reload"
    check("typing narrows it by any word in the title or key", reg.rows().map(\.id) == ["panel.reload"])
    reg.chosen = 0
    reg.runChosen()
    check("Return runs the chosen action and closes the palette", ran == ["reload"] && reg.palette == nil)
    reg.open(.goTo)
    check("⌘J shows places only", reg.rows().map(\.id) == ["place.notes"])
    reg.query = "zzz"
    check("no match is an empty list, not a crash", reg.rows().isEmpty)
    reg.close()
    reg.currentTab = { "notes" }; reg.currentDepth = { "row" }
    let h = reg.hintRows()
    check("hints on a focused note show its row keys and the list keys, not the typing keys",
          h.contains { $0.id == "notes.row.pin" } && h.contains { $0.id == "notes.list.move" } && !h.contains { $0.id == "notes.field.save" })
    reg.currentDepth = { "field" }
    check("hints while typing show the typing keys only", reg.hintRows().filter { $0.surface == "notes" }.allSatisfy { $0.depth == "field" })
    reg.currentTab = { "agents" }; reg.currentDepth = { "tab" }
    check("hints on any other tab show the generic row keys", reg.hintRows().contains { $0.id == "agents.row.open" })
    let was = reg.hintsPinned
    reg.hintsPinned = true
    check("the ⓘ keeps the hints up without ⌘", reg.showHints && !reg.hints)
    reg.hintsPinned = was
    return lines
}
