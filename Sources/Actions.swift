// Actions.swift
// Every key the panel answers, written down once. The palette (⇧⌘P), the hint
// strip (hold ⌘) and the probe all read this one table, so a key can never be
// bound without being findable, and the hints can never disagree with the
// palette. Rules: docs/plans/20261010-keyboard-convention.md

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One thing a key does on one surface. `run` is nil for a key that only moves
/// the keyboard (↑/↓, Escape): it is listed so the owner can find it, but the
/// palette has nothing to run for it.
struct KeyAction: Identifiable, Equatable {
    static func == (a: KeyAction, b: KeyAction) -> Bool { a.id == b.id }
    let id: String
    let title: String
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
    static func a(_ id: String, _ title: String, _ key: String, _ surface: String = "panel", _ depth: String = "anywhere") -> KeyAction {
        KeyAction(id: id, title: title, key: key, surface: surface, depth: depth)
    }

    /// Works on every tab, at every depth.
    static let panel: [KeyAction] = [
        a("panel.leader", "Open Switchboard, then show the jump letters, then close", "⌘⌘"),
        a("panel.chord.notes", "Open Notes from anywhere", "⌃⌥⌘N"),
        a("panel.chord.usage", "Open Usage from anywhere", "⌃⌥⌘U"),
        a("panel.chord.home", "Open Home from anywhere", "⌃⌥⌘B"),
        a("panel.chord.leader", "Open Switchboard from anywhere", "⌃⌥⌘Space"),
        a("panel.palette", "Find any action or place", "⇧⌘P"),
        a("panel.goto", "Go to a tab, a note or a timer", "⇧⌘A"),
        a("panel.keys", "The keys that work right here", "⌘/ or hold ⌘"),
        a("panel.space", "Pick a space", "⌘1 to ⌘5"),
        a("panel.tab.next", "Next tab in this space", "⌘⌥→"),
        a("panel.tab.prev", "Previous tab in this space", "⌘⌥←"),
        a("panel.tab.walk", "Walk every tab", "⌃Tab / ⌃⇧Tab"),
        a("panel.pin", "Pin this tab to the desktop", "⌘D"),
        a("panel.reload", "Reload this tab", "⌘R"),
        a("panel.settings", "Open Settings", "⌘,"),
        a("panel.close", "Step out, then close the panel", "Esc"),
    ]

    /// Any tab whose rows take keys by being rows (Keys.swift, KeyRows).
    static func generic(_ tab: String) -> [KeyAction] { [
        a("\(tab).row.move", "Move between rows", "↑/↓", tab, "tab"),
        a("\(tab).row.open", "Do what a click on the row does", "Return", tab, "row"),
        a("\(tab).row.flip", "Flip the row's switch", "Space", tab, "row"),
        a("\(tab).row.step", "Step a slider, or open and close a row with children", "←/→", tab, "row"),
        a("\(tab).row.search", "Type in the search box", "⌘L / ⌘F", tab, "tab"),
        a("\(tab).row.letgo", "Let go of the row", "Esc", tab, "row"),
    ] }

    static let notes: [KeyAction] = [
        a("notes.compose.type", "Write the new note (⇧Return for the body)", "type", "notes", "tab"),
        a("notes.compose.save", "Save the new note and keep writing in it", "⌘Return", "notes", "field"),
        a("notes.compose.leave", "Leave the new note, draft kept", "Esc", "notes", "field"),
        a("notes.list.move", "Move between notes", "↑/↓", "notes", "tab"),
        a("notes.list.filter", "Along the colour filter; Space toggles a colour", "←/→", "notes", "tab"),
        a("notes.list.search", "Search", "/", "notes", "tab"),
        a("notes.row.open", "Open the note to read", "→ or Return", "notes", "row"),
        a("notes.row.pin", "Pin or unpin", "P", "notes", "row"),
        a("notes.row.copy", "Copy title and body", "C", "notes", "row"),
        a("notes.row.color", "Set a colour (0 clears)", "1 to 8", "notes", "row"),
        a("notes.row.delete", "Delete, with a confirm", "⌫", "notes", "row"),
        a("notes.open.parts", "Move between title, body, tags, expiry, reminder, colour, pin, copy, delete", "↑/↓ or Tab", "notes", "open"),
        a("notes.open.edit", "Start typing in the chosen part", "→ or Return", "notes", "open"),
        a("notes.open.copyall", "Copy title and body together", "⇧⌘C", "notes", "open"),
        a("notes.open.close", "Close the note", "← or Esc", "notes", "open"),
        a("notes.field.stop", "Stop typing and save; the note stays open", "Esc", "notes", "field"),
        a("notes.field.save", "Save now and keep typing", "⌘Return", "notes", "field"),
    ]

    static let timers: [KeyAction] = [
        a("timers.field.leave", "Leave the new timer for the list", "Esc", "timers", "field"),
        a("timers.list.move", "Move between timers (↑ from the first goes back to the box)", "↑/↓", "timers", "tab"),
        a("timers.row.rename", "Rename", "Return", "timers", "row"),
        a("timers.row.extend", "Add a minute", "+", "timers", "row"),
        a("timers.row.clear", "Clear the timer", "⌫", "timers", "row"),
    ]

    static let home: [KeyAction] = [
        a("home.list.move", "Move between bulbs", "↑/↓", "home", "tab"),
        a("home.row.switch", "Switch the bulb on or off", "Space", "home", "row"),
        a("home.row.dim", "Brightness", "←/→", "home", "row"),
        a("home.row.warm", "Warmth", "⇧←/⇧→", "home", "row"),
        a("home.row.strip", "Open the colour strip", "Return", "home", "row"),
        a("home.row.color", "Pick a colour from the open strip", "1 to 8", "home", "row"),
    ]

    static let approvals: [KeyAction] = [
        a("approvals.row.move", "Move between requests", "↑/↓", "approvals", "tab"),
        a("approvals.row.open", "Open the request", "Return", "approvals", "row"),
        a("approvals.open.allow", "Allow the open request", "⌘Return", "approvals", "open"),
        a("approvals.open.deny", "Deny the open request", "⌫", "approvals", "open"),
        a("approvals.open.back", "Close the panel; focus goes back to the app you came from", "Esc", "approvals", "open"),
    ]

    static let controls: [KeyAction] = [
        a("controls.row.move", "Move between sound, display, Wi-Fi, Bluetooth and its devices", "↑/↓", "controls", "tab"),
        a("controls.row.flip", "Mute, Wi-Fi or Bluetooth on and off, connect or disconnect a device", "Space", "controls", "row"),
        a("controls.row.step", "Volume or brightness, 5% a step", "←/→", "controls", "row"),
        a("controls.row.letgo", "Let go of the row", "Esc", "controls", "row"),
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

    @Published var palette: PaletteMode?
    @Published var query = ""
    @Published var chosen = 0
    /// ⌘ has been held long enough to ask for the hints.
    @Published var hints = false

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
    /// since a row is one ↓ away.
    func hintRows() -> [KeyAction] {
        let tab = currentTab(), depth = currentDepth()
        let own = KeyTable.actions(for: tab).filter { $0.surface != "panel" }
        let depths: Set<String> = depth == "field" ? ["field"] : depth == "open" ? ["open"] : ["tab", "row"]
        let here = own.filter { depths.contains($0.depth) }
        let panelKeys = KeyTable.panel.filter { ["panel.palette", "panel.goto", "panel.tab.next", "panel.space", "panel.close"].contains($0.id) }
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
    static let hold: TimeInterval = 0.7
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

/// A key, drawn as a small pill.
struct KeyPill: View {
    let text: String
    var body: some View {
        Text(text).font(.sb(10, weight: .semibold).monospaced())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.18)))
    }
}

/// Hold ⌘: the keys that work where the keyboard is, as pills in a strip.
struct HintStrip: View {
    @ObservedObject private var reg = ActionRegistry.shared
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(reg.hintRows()) { r in
                HStack(spacing: 3) {
                    KeyPill(text: r.key)
                    Text(r.title).font(.sb(10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .accessibilityIdentifier("hint-strip")
    }
}

/// ⇧⌘P: a search box over every action and place; ↑/↓ choose, Return runs.
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
                Image(systemName: "command").font(.sbIcon(11)).foregroundStyle(.secondary)
                TextField(prompt, text: $reg.query)
                    .textFieldStyle(.plain).font(PT.label)
                    .focused($typing)
                    .onChange(of: reg.query) { _ in reg.chosen = 0 }
                KeyPill(text: "Esc")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
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
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == reg.chosen ? Color.accentColor.opacity(0.16) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { reg.chosen = i; reg.runChosen() }
                                .id(r.id)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: reg.chosen) { i in
                        if rows.indices.contains(i) { withAnimation(Motion.fast) { proxy.scrollTo(rows[i].id) } }
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
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
          ["⌘⌘", "⌃Tab", "⌘1 to ⌘5", "⌘⌥→", "⇧⌘P", "⇧⌘A"].allSatisfy { k in KeyTable.panel.contains { $0.key.contains(k) } })

    let reg = ActionRegistry.shared
    var ran: [String] = []
    reg.runners = ["panel.reload": { ran.append("reload") }]
    reg.places = { [KeyAction(id: "place.notes", title: "Go to Notes", key: "N", surface: "place", depth: "anywhere", run: { ran.append("notes") })] }
    reg.currentTab = { "usage" }
    reg.open(.all)
    check("the palette lists places and the tab's keys", reg.rows().contains { $0.id == "place.notes" } && reg.rows().contains { $0.id == "usage.row.move" })
    reg.query = "reload"
    check("typing narrows it by any word in the title or key", reg.rows().map(\.id) == ["panel.reload"])
    reg.chosen = 0
    reg.runChosen()
    check("Return runs the chosen action and closes the palette", ran == ["reload"] && reg.palette == nil)
    reg.open(.goTo)
    check("⇧⌘A shows places only", reg.rows().map(\.id) == ["place.notes"])
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
    return lines
}
