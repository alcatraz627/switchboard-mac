// Keys.swift
// Switchboard by keyboard. One grammar for every surface: the keyboard always
// sits somewhere, arrows move at that depth, Return or → goes one deeper,
// Escape or ← comes back up, and typing only happens at the deepest depth.
// The rules are plain functions so a probe can walk them key by key; the
// views read where the keyboard is from a per-window model and draw a ring.
// The full set, as the owner reads it: docs/plans/20261003-round7-keyboard.md

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// ── Keys, as the rules see them ─────────────────────────────────────────────

enum Key: Equatable {
    case up, down, left, right, enter, escape, space, delete
    /// ⇧← and ⇧→: the second slider on a row (a bulb's warmth).
    case shiftLeft, shiftRight
    /// Tab and ⇧Tab: the next or previous part of an open note.
    case tab, backTab
    /// ⌘↩: save now.
    case save
    /// ⇧⌘C: copy title and body together.
    case copyAll
    /// A plain character with no modifier (letters, digits, "/", "+").
    case char(Character)

    /// The key an event stands for, or nil for one the rules never look at.
    init?(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods == .command { self = .save; return }
            if mods.isEmpty { self = .enter; return }
            return nil
        case kVK_Escape: self = .escape; return
        case kVK_Tab where mods.isEmpty: self = .tab; return
        case kVK_Tab where mods == .shift: self = .backTab; return
        case kVK_UpArrow where mods.isEmpty: self = .up; return
        case kVK_DownArrow where mods.isEmpty: self = .down; return
        case kVK_LeftArrow where mods.isEmpty: self = .left; return
        case kVK_RightArrow where mods.isEmpty: self = .right; return
        case kVK_LeftArrow where mods == .shift: self = .shiftLeft; return
        case kVK_RightArrow where mods == .shift: self = .shiftRight; return
        case kVK_Space where mods.isEmpty: self = .space; return
        case kVK_Delete, kVK_ForwardDelete: if mods.isEmpty { self = .delete; return }; return nil
        case kVK_ANSI_C where mods == [.command, .shift]: self = .copyAll; return
        default: break
        }
        guard mods.isEmpty || mods == .shift, let c = e.charactersIgnoringModifiers?.lowercased().first,
              c.isLetter || c.isNumber || "+=/".contains(c) else { return nil }
        self = .char(c)
    }
}

// ── Notes: where the keyboard is, and what each key does there ──────────────

/// The parts of an open note, in the order the keyboard walks them.
enum NoteBlock: CaseIterable, Equatable {
    case title, body, tags, expiry, reminder, color, pin, copy, delete
    /// Parts that are typed into; the rest are acted on.
    var isText: Bool { self == .title || self == .body || self == .tags }
    /// Parts whose action opens a small picker.
    var opensPicker: Bool { self == .expiry || self == .reminder || self == .color }
    func step(_ by: Int) -> NoteBlock {
        let all = Self.allCases
        let i = all.firstIndex(of: self)!
        return all[max(0, min(all.count - 1, i + by))]
    }
}

/// Which part of a note a copy takes.
enum NotePart: Equatable { case all, title, text, path }

enum NoteFocus: Equatable {
    /// Nothing on the tab has the keyboard.
    case none
    /// Writing the new note at the top.
    case compose
    /// Typing in the search box.
    case search
    /// A dot on the colour filter row; 0 is "all".
    case filter(Int)
    /// A note in the list, closed.
    case row(String)
    /// A note open on one of its parts. `typing` false is reading (select and
    /// copy, nothing changes); true is editing a text part. A part of nil means
    /// nothing is chosen yet (a click opened it).
    case open(String, NoteBlock?, typing: Bool)

    var noteID: String? {
        switch self {
        case .row(let id), .open(let id, _, _): return id
        default: return nil
        }
    }
}

/// What a key asks for beyond moving the keyboard.
enum NoteEffect: Equatable {
    case saveCompose
    case saveNote(String)
    case copy(String, NotePart)
    case togglePin(String)
    /// A colour by its place in the eight; 0 clears it.
    case color(String, Int)
    case delete(String)
    case toggleFilter(Int)
    /// Opens the expiry, reminder or colour picker of the open note.
    case openPicker(NoteBlock)
    case clearSearch
}

enum NotesKeys {
    struct Context {
        /// The notes the list shows, top to bottom, after the filter and search.
        var ids: [String]
        /// Dots on the filter row, "all" included.
        var filterCount = timerColors.count + 1
        /// An editable text field has the keyboard right now.
        var typing = false
        /// Something is typed in the search box.
        var searching = false
    }

    /// The part `by` steps away, and whether the keyboard types there.
    private static func walk(_ id: String, from b: NoteBlock?, by: Int, typing: Bool) -> NoteFocus {
        let to = b.map { $0.step(by) } ?? .title
        return .open(id, to, typing: typing && to.isText)
    }

    /// One key at one place: where the keyboard goes, what else happens, and
    /// whether the key was used (an unused key goes on to the text field).
    static func reduce(_ f: NoteFocus, _ k: Key, _ c: Context) -> (NoteFocus, [NoteEffect], Bool) {
        let first = c.ids.first.map(NoteFocus.row) ?? .filter(0)
        // a field the rules did not hand the keyboard to keeps every key
        if c.typing, !f.isTyping { return (f, [], false) }
        switch f {
        case .none:
            switch k {
            case .down: return (.compose, [], true)
            case .up: return (c.ids.last.map(NoteFocus.row) ?? .compose, [], true)
            case .enter: return (.compose, [], true)
            case .char("/"): return (.search, [], true)
            default: return (f, [], false)
            }

        case .compose:
            switch k {
            // the draft stays where it is; the list takes the keyboard
            case .escape: return (first, [], true)
            case .save: return (f, [.saveCompose], true)
            default: return (f, [], false)
            }

        case .search:
            switch k {
            // Escape empties the search first, then leaves it
            case .escape: return c.searching ? (f, [.clearSearch], true) : (first, [], true)
            case .down, .enter: return (first, [], true)
            case .up: return (.compose, [], true)
            default: return (f, [], false)
            }

        case .filter(let i):
            switch k {
            case .left: return (.filter(max(0, i - 1)), [], true)
            case .right: return (.filter(min(c.filterCount - 1, i + 1)), [], true)
            case .space, .enter: return (f, [.toggleFilter(i)], true)
            case .up: return (.search, [], true)
            case .down: return (c.ids.first.map(NoteFocus.row) ?? f, [], true)
            case .escape: return (.none, [], true)
            case .char("/"): return (.search, [], true)
            default: return (f, [], false)
            }

        case .row(let id):
            let at = c.ids.firstIndex(of: id)
            switch k {
            case .up:
                guard let at, at > 0 else { return (.filter(0), [], true) }
                return (.row(c.ids[at - 1]), [], true)
            case .down:
                guard let at else { return (first, [], true) }
                return (.row(c.ids[min(c.ids.count - 1, at + 1)]), [], true)
            case .right, .enter, .space: return (.open(id, .title, typing: false), [], true)
            case .left: return (f, [], true)
            case .escape: return (.none, [], true)
            case .char("/"): return (.search, [], true)
            case .char("p"): return (f, [.togglePin(id)], true)
            case .char("c"), .copyAll: return (f, [.copy(id, .all)], true)
            case .char(let d) where d.isNumber:
                let n = d.wholeNumberValue ?? 0
                return n <= timerColors.count ? (f, [.color(id, n)], true) : (f, [], true)
            case .delete: return (f, [.delete(id)], true)
            default: return (f, [], false)
            }

        case .open(let id, let b, typing: false):
            switch k {
            case .up, .backTab: return (b == nil || b == .title ? .open(id, .title, typing: false) : walk(id, from: b, by: -1, typing: false), [], true)
            case .down, .tab: return (walk(id, from: b ?? .title, by: b == nil ? 0 : 1, typing: false), [], true)
            case .right, .enter:
                let part = b ?? .title
                if part.isText { return (.open(id, part, typing: true), [], true) }
                switch part {
                case .pin: return (f, [.togglePin(id)], true)
                case .copy: return (f, [.copy(id, .all)], true)
                case .delete: return (f, [.delete(id)], true)
                default: return (f, [.openPicker(part)], true)
                }
            case .left, .escape: return (.row(id), [], true)
            case .copyAll: return (f, [.copy(id, .all)], true)
            // on the copy part, a letter picks what to copy
            case .char("t") where b == .copy: return (f, [.copy(id, .title)], true)
            case .char("x") where b == .copy: return (f, [.copy(id, .text)], true)
            case .char("l") where b == .copy: return (f, [.copy(id, .path)], true)
            case .char(let d) where d.isNumber && b == .color:
                let n = d.wholeNumberValue ?? 0
                return n <= timerColors.count ? (f, [.color(id, n)], true) : (f, [], true)
            // ⌘A and ⌘C belong to the chosen text part, which holds the keyboard read-only
            default: return (f, [], false)
            }

        case .open(let id, let b, typing: true):
            switch k {
            // Escape stops typing and keeps the note open to read; the edit is saved
            case .escape:
                return (b == nil ? .row(id) : .open(id, b, typing: false), [.saveNote(id)], true)
            case .save: return (f, [.saveNote(id)], true)
            // Tab carries on to the next part: typing if it is text, reading if not
            case .tab: return (walk(id, from: b, by: 1, typing: true), [.saveNote(id)], true)
            case .backTab: return (walk(id, from: b, by: -1, typing: true), [.saveNote(id)], true)
            default:
                // a note opened by a click with no field chosen still answers the arrows
                if b == nil, !c.typing {
                    switch k {
                    case .up, .down: return (.open(id, .title, typing: false), [], true)
                    case .left: return (.row(id), [], true)
                    default: break
                    }
                }
                return (f, [], false)
            }
        }
    }
}

extension NoteFocus {
    /// Whether the rules expect a text field to have the keyboard here.
    var isTyping: Bool {
        switch self {
        case .compose, .search: return true
        case .open(_, _, let t): return t
        default: return false
        }
    }
}

/// Where the keyboard is on one window's Notes tab: the search, the colour
/// filter, which picker is open, and the new note being written (kept across
/// Escape and tab changes).
final class NotesNav: ObservableObject {
    private static var spaces: [String: NotesNav] = [:]
    static func forSpace(_ s: String) -> NotesNav {
        if let n = spaces[s] { return n }
        let n = NotesNav(); spaces[s] = n; return n
    }

    @Published var focus: NoteFocus = .none
    @Published var filter: Set<String> = []
    @Published var query = ""
    @Published var draftTitle = ""
    @Published var draftBody = ""
    @Published var draftColor: String?
    /// The open note's expiry, reminder or colour picker, while it shows.
    @Published var picker: NoteBlock?
    /// Which field of the new note was last typed in.
    var composeField: NoteBlock = .title
    /// Where the cursor lands when typing moves into a note from outside.
    var caret: Int?
    /// Bumped to ask the open note to save now (⌘↩).
    @Published var saveTick = 0

    /// The notes the list shows: in a chosen colour, if any, and matching every word searched for.
    func visible(_ notes: [Note]) -> [Note] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return notes.filter { n in
            (filter.isEmpty || (n.color.flatMap(tagColorName).map(filter.contains) ?? false))
                && words.allSatisfy { w in
                    n.title.lowercased().contains(w) || n.body.lowercased().contains(w) || n.tags.contains { $0.lowercased().contains(w) }
                }
        }
    }

    /// Saves the new note. The saved note opens for typing in the same field,
    /// with the cursor where it was, so writing carries on in it.
    @discardableResult
    func saveCompose(_ store: NotesStore, caret at: Int?) -> Note? {
        guard InputRules.canSave(title: draftTitle, body: draftBody),
              let n = store.add(title: draftTitle, body: draftBody, color: draftColor) else { return nil }
        draftTitle = ""; draftBody = ""; draftColor = nil
        // a filter or search that would hide the note just written is lifted
        if !visible([n]).contains(where: { $0.id == n.id }) { filter = []; query = "" }
        caret = at
        focus = .open(n.id, composeField, typing: true)
        return n
    }

    func toggleFilter(_ i: Int) {
        guard i > 0 else { filter = []; return }
        let name = timerColors[i - 1].0
        if filter.contains(name) { filter.remove(name) } else { filter.insert(name) }
    }
}

// ── Rows with a few actions each: bulbs and timers ──────────────────────────

enum RowFocus: Equatable {
    case none
    /// The tab's own input on top (the new timer's label), typing.
    case field
    case row(String)
}

enum RowKeys {
    /// Moving between rows. `hasField` says the tab has an input above its rows.
    static func move(_ f: RowFocus, _ k: Key, ids: [String], hasField: Bool, typing: Bool) -> (RowFocus, Bool) {
        if typing {
            // only Escape leaves a field; it hands the keyboard to the first row
            guard k == .escape, f == .field else { return (f, false) }
            return (ids.first.map(RowFocus.row) ?? .none, true)
        }
        switch f {
        case .none, .field:
            switch k {
            case .down: return (ids.first.map(RowFocus.row) ?? f, true)
            case .up: return (ids.last.map(RowFocus.row) ?? f, true)
            default: return (f, false)
            }
        case .row(let id):
            let at = ids.firstIndex(of: id) ?? 0
            switch k {
            case .up: return (at > 0 ? .row(ids[at - 1]) : (hasField ? .field : f), true)
            case .down: return (.row(ids[min(ids.count - 1, at + 1)]), true)
            case .escape: return (.none, true)
            default: return (f, false)
            }
        }
    }
}

/// Where the keyboard is on one window's Home or Timers tab, and which row
/// has its colour strip open or its name being edited.
final class RowNav: ObservableObject {
    private static var spaces: [String: RowNav] = [:]
    static func forSpace(_ s: String, _ tab: String) -> RowNav {
        let k = s + "/" + tab
        if let n = spaces[k] { return n }
        let n = RowNav(); spaces[k] = n; return n
    }
    @Published var focus: RowFocus = .none
    @Published var expanded: String?
    @Published var renaming: String?
    var focusedID: String? { if case .row(let id) = focus { return id }; return nil }
}

// ── Every other tab: rows that take keys by being rows ──────────────────────

/// What a row can do from the keyboard. Each is optional; a row offers what it has.
struct RowKeyActions {
    /// Return: what a click on the row does.
    var primary: (() -> Void)?
    /// Space: flip its switch, or do the primary.
    var toggle: (() -> Void)?
    /// ← and →: step a slider or a choice, -1 or +1.
    var step: ((Int) -> Void)?
    /// → opens, ← closes, for a row with children. Answers whether it is open.
    var isOpen: (() -> Bool)?
    var setOpen: ((Bool) -> Void)?
}

/// The rows on one window's tabs that take keys, by where they sit on screen,
/// and which one has the keyboard. Rows register themselves as they draw.
final class KeyRows: ObservableObject {
    private static var spaces: [String: KeyRows] = [:]
    static func forSpace(_ s: String) -> KeyRows {
        if let r = spaces[s] { return r }
        let r = KeyRows(); spaces[s] = r; return r
    }
    @Published var focused: String?
    private(set) var rows: [String: (frame: CGRect, actions: RowKeyActions)] = [:]

    func set(_ key: String, frame: CGRect, actions: RowKeyActions) { rows[key] = (frame, actions) }
    func remove(_ key: String) { rows[key] = nil; if focused == key { focused = nil } }
    /// Keys in reading order: top to bottom, then left to right.
    var ordered: [String] {
        rows.sorted { a, b in abs(a.value.frame.minY - b.value.frame.minY) > 2 ? a.value.frame.minY < b.value.frame.minY
                                                                              : a.value.frame.minX < b.value.frame.minX }.map(\.key)
    }

    /// One key: true when it was used.
    func handle(_ k: Key) -> Bool {
        let keys = ordered
        guard !keys.isEmpty else { return false }
        let at = focused.flatMap { keys.firstIndex(of: $0) }
        let a = focused.flatMap { rows[$0]?.actions }
        switch k {
        case .down: focused = keys[at.map { min(keys.count - 1, $0 + 1) } ?? 0]
        case .up: focused = keys[at.map { max(0, $0 - 1) } ?? keys.count - 1]
        case .escape:
            guard focused != nil else { return false }
            focused = nil
        case .enter:
            guard let a else { return false }
            if let o = a.isOpen, let s = a.setOpen, a.primary == nil { s(!o()) } else { a.primary?() }
        case .right:
            guard let a else { return false }
            if let s = a.setOpen, a.isOpen?() == false { s(true) } else if let st = a.step { st(1) } else { return false }
        case .left:
            guard let a else { return false }
            if let s = a.setOpen, a.isOpen?() == true { s(false) } else if let st = a.step { st(-1) } else { return false }
        case .space:
            guard let a else { return false }
            (a.toggle ?? a.primary)?()
        default: return false
        }
        if let f = focused { FocusScroll.shared.show("kr-" + f) }
        return true
    }
}

private struct KeyRowModifier: ViewModifier {
    let key: String
    let actions: RowKeyActions
    @Environment(\.panelSpace) private var space
    @ObservedObject private var registry: KeyRows

    init(key: String, actions: RowKeyActions, space: String) {
        self.key = key; self.actions = actions
        _registry = ObservedObject(wrappedValue: KeyRows.forSpace(space))
    }

    func body(content: Content) -> some View {
        content
            .keyRing(registry.focused == key, radius: 5)
            .id("kr-" + key)
            .background(GeometryReader { g in
                let f = g.frame(in: .named(space))
                Color.clear
                    .onAppear { KeyRows.forSpace(space).set(key, frame: f, actions: actions) }
                    .onChange(of: f) { nf in KeyRows.forSpace(space).set(key, frame: nf, actions: actions) }
                    .onDisappear { KeyRows.forSpace(space).remove(key) }
            })
    }
}

private struct KeyRowHost: ViewModifier {
    let key: String
    let actions: RowKeyActions
    @Environment(\.panelSpace) private var space
    func body(content: Content) -> some View { content.modifier(KeyRowModifier(key: key, actions: actions, space: space)) }
}

extension View {
    /// Makes this row reachable with ↑/↓ and actionable by keys, wherever it is drawn.
    func keyRow(_ key: String, _ actions: RowKeyActions) -> some View { modifier(KeyRowHost(key: key, actions: actions)) }
}

/// Asks the open panel to bring a row into view, without the reveal flash.
final class FocusScroll: ObservableObject {
    static let shared = FocusScroll()
    @Published private(set) var key: String?
    func show(_ key: String) { self.key = key }
}

// ── The router: one key event, in one window, on one tab ────────────────────

enum KeyRouter {
    /// Hands a key to the tab that has it. True when the key was used.
    static func handle(_ e: NSEvent, space: String, tab: String?) -> Bool {
        guard let k = Key(e) else { return false }
        switch tab {
        case "notes": return notes(k, space: space, window: e.window)
        case "home": return bulbs(k, space: space, window: e.window)
        case "timers": return timers(k, space: space, window: e.window)
        default: return rows(k, space: space, window: e.window)
        }
    }

    /// Any other tab: its rows by ↑/↓, acted on by Return, Space, ← and →. From a
    /// search box, ↓ steps down into the rows; every other key stays the box's.
    private static func rows(_ k: Key, space: String, window: NSWindow?) -> Bool {
        let typing = (window?.firstResponder as? NSTextView)?.isEditable == true
        if typing {
            guard k == .down else { return false }
            window?.makeFirstResponder(nil)
        }
        return KeyRows.forSpace(space).handle(k)
    }

    /// Bulbs: Space switches, ←/→ brightness and ⇧←/⇧→ warmth in the wheel's steps,
    /// Return opens the colour strip, 1 to 8 pick a colour from it.
    static var lights: LightsStore?
    private static func bulbs(_ k: Key, space: String, window: NSWindow?) -> Bool {
        guard let lights else { return false }
        let nav = RowNav.forSpace(space, "home")
        let typing = (window?.firstResponder as? NSTextView)?.isEditable == true
        let ids = lights.bulbs.map(\.id)
        let (to, moved) = RowKeys.move(nav.focus, k, ids: ids, hasField: false, typing: typing)
        if moved { nav.focus = to; if let id = nav.focusedID { FocusScroll.shared.show(BulbRow.revealKey(id)) }; return true }
        guard !typing, let id = nav.focusedID, let b = lights.bulbs.first(where: { $0.id == id }), b.reachable else { return false }
        switch k {
        case .space: lights.set(b, ["state=\(b.on ? "off" : "on")"])
        case .left, .right:
            guard b.on else { return true }
            let d = min(100, max(10, b.dimming + (k == .right ? 5 : -5)))
            lights.set(b, ["dimming=\(d)"])
        case .shiftLeft, .shiftRight:
            guard b.on else { return true }
            let t = min(6500, max(2200, (b.temp ?? 2700) + (k == .shiftRight ? 200 : -200)))
            lights.set(b, ["temp=\(t / 100 * 100)"])
        case .enter: nav.expanded = nav.expanded == id ? nil : id
        case .char(let c) where c.isNumber:
            guard nav.expanded == id, b.on, let n = c.wholeNumberValue, n >= 1, n <= BulbRow.swatches.count else { return true }
            lights.set(b, ["rgb=\(BulbRow.swatches[n - 1].0)"])
        default: return false
        }
        return true
    }

    /// Timers: Escape leaves the new timer's label for the list, ↑ from the first
    /// timer goes back to it; Return renames, + adds a minute, ⌫ clears.
    private static func timers(_ k: Key, space: String, window: NSWindow?) -> Bool {
        let store = TimerStore.shared
        let nav = RowNav.forSpace(space, "timers")
        let typing = (window?.firstResponder as? NSTextView)?.isEditable == true
        // a rename in progress keeps every key; its own Enter and Escape finish it
        if nav.renaming != nil { return false }
        let ids = store.timers.map(\.id)
        let (to, moved) = RowKeys.move(typing ? .field : nav.focus, k, ids: ids, hasField: true, typing: typing)
        if moved {
            nav.focus = to
            if typing, to != .field { window?.makeFirstResponder(nil) }
            if let id = nav.focusedID { FocusScroll.shared.show("timer-" + id) }
            return true
        }
        guard !typing, let id = nav.focusedID, let t = store.timers.first(where: { $0.id == id }) else { return false }
        switch k {
        case .enter: nav.renaming = id
        case .char("+"), .char("="): store.extend(t, by: 60)
        case .delete:
            let ids = store.timers.map(\.id)
            let next = ids.firstIndex(of: id).flatMap { i in ids.indices.contains(i + 1) ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil) }
            store.remove(t)
            nav.focus = next.map(RowFocus.row) ?? .field
        default: return false
        }
        return true
    }

    private static func notes(_ k: Key, space: String, window: NSWindow?) -> Bool {
        let nav = NotesNav.forSpace(space)
        let store = NotesStore.shared
        let tv = window?.firstResponder as? NSTextView
        let typing = tv?.isEditable == true
        let ctx = NotesKeys.Context(ids: nav.visible(store.live).map(\.id), typing: typing, searching: !nav.query.isEmpty)
        let (to, effects, used) = NotesKeys.reduce(nav.focus, k, ctx)
        for fx in effects {
            switch fx {
            case .saveCompose: nav.saveCompose(store, caret: tv?.selectedRange().location)
            case .saveNote: nav.saveTick += 1
            case .copy(let id, let part):
                guard let n = store.notes.first(where: { $0.id == id }) else { break }
                copyNote(n, part)
            case .togglePin(let id):
                guard var n = store.notes.first(where: { $0.id == id }) else { break }
                n.pinned.toggle(); store.update(n)
            case .color(let id, let i):
                guard var n = store.notes.first(where: { $0.id == id }) else { break }
                n.color = i == 0 ? nil : timerColors[i - 1].0; store.update(n)
            case .delete(let id):
                guard let n = store.notes.first(where: { $0.id == id }) else { break }
                let a = NSAlert(); a.messageText = "Delete \u{201C}\(n.heading)\u{201D}?"
                a.informativeText = "The file and any reminder it set are removed."
                a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn {
                    let ids = ctx.ids
                    let next = ids.firstIndex(of: id).flatMap { i in ids.indices.contains(i + 1) ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil) }
                    store.delete(n)
                    nav.focus = next.map(NoteFocus.row) ?? .filter(0)
                }
            case .toggleFilter(let i): nav.toggleFilter(i)
            case .openPicker(let part): nav.picker = part
            case .clearSearch: nav.query = ""
            }
        }
        // a save that moved the keyboard into the new note wins over the rules' answer
        if !effects.contains(.saveCompose), to != nav.focus { nav.focus = to }
        if let id = nav.focus.noteID { FocusScroll.shared.show("note-" + id) }
        // a picker belongs to its part: moving off the part closes it
        if let p = nav.picker, nav.focus != .open(nav.focus.noteID ?? "", p, typing: false) { nav.picker = nil }
        // leaving the text fields takes the keyboard off them, so the panel hears the arrows;
        // a title or body going from typing to reading keeps it, read-only, on the same text
        if typing, !nav.focus.isTyping {
            if case .open(_, let b?, typing: false) = nav.focus, b == .title || b == .body, tv is EditorTextView {
                tv?.isEditable = false
            } else { window?.makeFirstResponder(nil) }
        }
        return used
    }

    /// Copies one part of a note and says so at the bottom of the panel.
    static func copyNote(_ n: Note, _ part: NotePart) {
        let (text, what): (String, String) = {
            switch part {
            case .all: return (n.content, "\u{201C}\(n.heading)\u{201D}")
            case .title: return (n.title, "the title")
            case .text: return (n.body, "the text")
            case .path: return (n.path, "the file's path")
            }
        }()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.shared.show("Copied " + what)
    }
}

/// A short line at the bottom of the panel saying what a key just did.
final class Toast: ObservableObject {
    static let shared = Toast()
    @Published private(set) var text: String?
    func show(_ s: String) {
        text = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in if self?.text == s { self?.text = nil } }
    }
}

// ── The keyboard ring ───────────────────────────────────────────────────────

extension View {
    /// The ring that says "the keyboard is here".
    func keyRing(_ on: Bool, radius: CGFloat = 6) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.accentColor.opacity(on ? 0.75 : 0), lineWidth: 1.5)
            .allowsHitTesting(false))
    }
}

// ── Getting in from anywhere ────────────────────────────────────────────────

/// The front door: ⌘ tapped twice, and ⌃⌥⌘ plus a letter for the tabs used most.
/// The chords use the system hotkey service and need no permission. Watching ⌘
/// on its own needs Input Monitoring, because it reads modifier keys system-wide;
/// without it, ⌃⌥⌘Space does the same job.
final class HotKeys {
    static let shared = HotKeys()
    /// ⌘⌘: open the panel, then (while open) show the jump letters, then close.
    var onDoubleCommand: () -> Void = {}
    /// A chord, by the tab it opens.
    var onChord: (String) -> Void = { _ in }

    /// The chords and the tab each opens; the leader is "leader".
    static let chords: [(key: Int, tab: String, label: String)] = [
        (kVK_ANSI_N, "notes", "⌃⌥⌘N"), (kVK_ANSI_U, "usage", "⌃⌥⌘U"), (kVK_ANSI_B, "home", "⌃⌥⌘B"),
        (kVK_Space, "leader", "⌃⌥⌘Space"),
    ]

    private var refs: [EventHotKeyRef?] = []
    private var monitors: [Any] = []
    private var tap = DoubleTap()

    func start() {
        registerChords()
        watchCommand()
    }

    /// Whether ⌘⌘ can be heard while another app is in front.
    static var commandWatchAllowed: Bool { AXIsProcessTrusted() }
    /// Asks macOS for the permission ⌘⌘ needs; System Settings opens on it.
    static func askForCommandWatch() {
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    private func registerChords() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let i = Int(id.id)
            if HotKeys.chords.indices.contains(i) {
                let tab = HotKeys.chords[i].tab
                DispatchQueue.main.async { HotKeys.shared.onChord(tab) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey | cmdKey)
        for (i, c) in Self.chords.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53574244), id: UInt32(i))   // "SWBD"
            let r = RegisterEventHotKey(UInt32(c.key), mods, id, GetApplicationEventTarget(), 0, &ref)
            if r != noErr { dlog("hotkey \(c.label) not registered (\(r)); another app may hold it") }
            refs.append(ref)
        }
    }

    private func watchCommand() {
        let feed: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            if self.tap.feed(e.type == .flagsChanged ? .flags(e.modifierFlags.intersection(.deviceIndependentFlagsMask)) : .other,
                             at: e.timestamp) {
                DispatchQueue.main.async { self.onDoubleCommand() }
            }
        }
        // global monitors only hear anything once the permission is given; local ones always do
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: feed) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { e in feed(e); return e }) {
            monitors.append(l)
        }
    }
}

/// Tells a double tap of ⌘ apart from ⌘ used in a shortcut: two short presses
/// of ⌘ alone, close together, with no other key or modifier in between.
struct DoubleTap {
    enum Input: Equatable { case flags(NSEvent.ModifierFlags), other }
    /// Longest a tap may be held, and longest the gap between two taps.
    static let hold: TimeInterval = 0.3
    static let gap: TimeInterval = 0.35

    private var downAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    /// True on the release that completes a double tap.
    mutating func feed(_ i: Input, at t: TimeInterval) -> Bool {
        switch i {
        case .other:
            downAt = nil; lastTapAt = nil
            return false
        case .flags(let f):
            let mods = f.intersection([.command, .shift, .option, .control, .function])
            if mods == .command { downAt = t; return false }
            if mods.isEmpty, let d = downAt {
                downAt = nil
                guard t - d <= Self.hold else { lastTapAt = nil; return false }
                if let last = lastTapAt, t - last <= Self.gap { lastTapAt = nil; return true }
                lastTapAt = t
                return false
            }
            downAt = nil; lastTapAt = nil
            return false
        }
    }
}

/// The panel's own keyboard state: whether it is listening for a jump letter.
final class PanelKeys: ObservableObject {
    static let shared = PanelKeys()
    @Published var jumping = false
}

/// The panel-wide keys, before a tab sees anything: ⌃Tab and ⌃⇧Tab walk the
/// tabs, ⌘1 to ⌘5 pick a space, and after ⌘⌘ a letter jumps to its tab.
enum PanelNav {
    enum Move: Equatable { case tab(String), close, none }

    /// `tabs` is the visible tabs in bar order; `spaces` each space's tabs.
    static func move(_ e: NSEvent, current: String, tabs: [String], spaces: [[String]], jumping: Bool) -> Move? {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if jumping {
            PanelKeys.shared.jumping = false
            if Int(e.keyCode) == kVK_Escape { return Move.none }
            if mods.isEmpty, let c = e.charactersIgnoringModifiers?.lowercased().first, let t = JumpLetters.tab(for: c) {
                if tabs.contains(t) { return .tab(t) }
                // a tab that is hidden right now (Approvals with nothing waiting) says so instead of doing nothing
                Toast.shared.show(t == "approvals" ? "Nothing waits on you" : "That tab is hidden in Settings")
                return Move.none
            }
            return nil
        }
        if Int(e.keyCode) == kVK_Tab, mods.contains(.control), let i = tabs.firstIndex(of: current) {
            let by = mods.contains(.shift) ? -1 : 1
            return .tab(tabs[(i + by + tabs.count) % tabs.count])
        }
        if mods == .command, let c = e.charactersIgnoringModifiers?.first, let n = c.wholeNumberValue, n >= 1, n <= spaces.count {
            let s = spaces[n - 1]
            return .tab(s.first { $0 == current } ?? s[0])
        }
        return nil
    }
}

/// The letter that jumps to each tab after ⌘⌘, shown in the panel while it listens.
enum JumpLetters {
    static let table: [(Character, String)] = [
        ("n", "notes"), ("t", "timers"), ("u", "usage"), ("b", "home"), ("a", "agents"), ("m", "plugins"),
        ("k", "rules"), ("y", "library"), ("l", "ledger"), ("q", "queue"), ("s", "system"), ("r", "runtime"),
        ("c", "controls"), ("o", "remote"), ("p", "approvals"), (",", "settings"),
    ]
    static func tab(for c: Character) -> String? { table.first { $0.0 == c }?.1 }
    static func letter(for tab: String) -> Character? { table.first { $0.1 == tab }?.0 }
}

// ── Probe ───────────────────────────────────────────────────────────────────

/// Walks the Notes keys and the ⌘⌘ detector with no window, step by step.
func probeKeys() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let c = NotesKeys.Context(ids: ["a", "b", "c"])
    func step(_ f: NoteFocus, _ k: Key, _ ctx: NotesKeys.Context = c) -> NoteFocus { NotesKeys.reduce(f, k, ctx).0 }

    // compose
    check("Escape in the new note hands the keyboard to the first note", step(.compose, .escape) == .row("a"))
    check("⌘↩ in the new note asks for a save", NotesKeys.reduce(.compose, .save, c).1 == [.saveCompose])
    check("typing keys in the new note go to the text", NotesKeys.reduce(.compose, .char("x"), c).2 == false)
    // list
    check("↓ walks the list and stops at the end", step(step(step(.row("a"), .down), .down), .down) == .row("c"))
    check("↑ from the first note reaches the colour filter", step(.row("a"), .up) == .filter(0))
    check("↑ from the filter reaches search, and ↑ from search the new note", step(.filter(3), .up) == .search && NotesKeys.reduce(.search, .up, NotesKeys.Context(ids: ["a"], typing: true)).0 == .compose)
    check("← and → move along the filter", step(step(.filter(0), .right), .right) == .filter(2) && step(.filter(0), .left) == .filter(0))
    check("Space on a filter dot toggles it", NotesKeys.reduce(.filter(2), .space, c).1 == [.toggleFilter(2)])
    // read
    check("→ opens a note to read, on its title", step(.row("b"), .right) == .open("b", .title, typing: false))
    check("↓ and ↑ move between title and body", step(.open("b", .title, typing: false), .down) == .open("b", .body, typing: false)
          && step(.open("b", .body, typing: false), .up) == .open("b", .title, typing: false))
    check("⌘A and ⌘C are left to the text while reading", NotesKeys.reduce(.open("b", .body, typing: false), .char("a"), c).2 == false)
    check("→ again starts typing in the chosen block", step(.open("b", .body, typing: false), .right) == .open("b", .body, typing: true))
    check("← closes a note being read", step(.open("b", .body, typing: false), .left) == .row("b"))
    // edit
    let typingCtx = NotesKeys.Context(ids: ["a", "b", "c"], typing: true)
    check("Escape while typing saves and keeps the note open to read",
          NotesKeys.reduce(.open("b", .body, typing: true), .escape, typingCtx) == (.open("b", .body, typing: false), [.saveNote("b")], true))
    check("arrows while typing move the cursor, not the list", NotesKeys.reduce(.open("b", .body, typing: true), .down, typingCtx).2 == false)
    check("⌘↩ while typing saves and keeps typing",
          NotesKeys.reduce(.open("b", .title, typing: true), .save, typingCtx) == (.open("b", .title, typing: true), [.saveNote("b")], true))
    // row actions
    check("P pins, C copies, a digit colours, ⌫ deletes",
          NotesKeys.reduce(.row("a"), .char("p"), c).1 == [.togglePin("a")] && NotesKeys.reduce(.row("a"), .char("c"), c).1 == [.copy("a", .all)]
          && NotesKeys.reduce(.row("a"), .char("3"), c).1 == [.color("a", 3)] && NotesKeys.reduce(.row("a"), .delete, c).1 == [.delete("a")])
    check("a search or tags box keeps its keys", NotesKeys.reduce(.row("a"), .down, typingCtx).2 == false)

    // every part of an open note, by Tab or arrows
    var at = NoteFocus.open("b", .title, typing: false)
    var path: [NoteBlock] = []
    for _ in 0..<9 { if case .open(_, let p?, _) = at { path.append(p) }; at = step(at, .tab) }
    check("Tab walks title, body, tags, expiry, reminder, colour, pin, copy, delete", path == NoteBlock.allCases)
    check("⇧Tab walks back", step(.open("b", .color, typing: false), .backTab) == .open("b", .reminder, typing: false))
    check("Tab while typing the title goes on typing in the body",
          NotesKeys.reduce(.open("b", .title, typing: true), .tab, typingCtx).0 == .open("b", .body, typing: true))
    check("Tab while typing the tags stops typing on the expiry",
          NotesKeys.reduce(.open("b", .tags, typing: true), .tab, typingCtx).0 == .open("b", .expiry, typing: false))
    check("Return on expiry, reminder or colour opens its picker",
          [NoteBlock.expiry, .reminder, .color].allSatisfy { NotesKeys.reduce(.open("b", $0, typing: false), .enter, c).1 == [.openPicker($0)] })
    check("Return on pin pins, on copy copies, on delete deletes",
          NotesKeys.reduce(.open("b", .pin, typing: false), .enter, c).1 == [.togglePin("b")]
          && NotesKeys.reduce(.open("b", .copy, typing: false), .enter, c).1 == [.copy("b", .all)]
          && NotesKeys.reduce(.open("b", .delete, typing: false), .enter, c).1 == [.delete("b")])
    check("on copy, T, X and L copy the title, the text and the path",
          NotesKeys.reduce(.open("b", .copy, typing: false), .char("t"), c).1 == [.copy("b", .title)]
          && NotesKeys.reduce(.open("b", .copy, typing: false), .char("l"), c).1 == [.copy("b", .path)])
    check("Return on tags starts typing them", step(.open("b", .tags, typing: false), .enter) == .open("b", .tags, typing: true))
    // search
    check("/ on a note goes to search", step(.row("a"), .char("/")) == .search)
    var sc = c; sc.typing = true; sc.searching = true
    check("Escape in a search with text empties it and stays", NotesKeys.reduce(.search, .escape, sc) == (.search, [.clearSearch], true))
    sc.searching = false
    check("Escape in an empty search goes to the first note", NotesKeys.reduce(.search, .escape, sc).0 == .row("a"))
    check("↓ from search goes to the first note", NotesKeys.reduce(.search, .down, sc).0 == .row("a"))
    let sn = NotesNav(); sn.query = "deploy prod"
    let hits = sn.visible([Note(id: "s1", title: "Deploy", body: "check prod first", tags: [], created: Date()), Note(id: "s2", title: "Deploy", body: "staging", tags: [], created: Date())]).count
    check("search keeps notes holding every word, in title, text or tags", hits == 1)

    // the filter and the save that follows the cursor into the new note
    let nav = NotesNav()
    nav.toggleFilter(4)
    check("a filter dot shows only that colour", nav.filter == ["green"])
    nav.toggleFilter(0)
    check("the first dot clears the filter", nav.filter.isEmpty)
    nav.draftTitle = "  "
    check("an empty new note is not saved", nav.saveCompose(NotesStore.shared, caret: 0) == nil)

    // ⌘⌘
    var d = DoubleTap()
    let cmd = DoubleTap.Input.flags(.command), up = DoubleTap.Input.flags([])
    let seq: [(DoubleTap.Input, TimeInterval)] = [(cmd, 0), (up, 0.08), (cmd, 0.2), (up, 0.28)]
    check("two quick taps of ⌘ are a double tap", seq.map { d.feed($0.0, at: $0.1) } == [false, false, false, true])
    d = DoubleTap()
    let shortcut: [(DoubleTap.Input, TimeInterval)] = [(cmd, 0), (.other, 0.05), (up, 0.1), (cmd, 0.2), (up, 0.28)]
    check("⌘ used in a shortcut never counts", shortcut.map { d.feed($0.0, at: $0.1) }.allSatisfy { !$0 })
    d = DoubleTap()
    let slow: [(DoubleTap.Input, TimeInterval)] = [(cmd, 0), (up, 0.08), (cmd, 0.9), (up, 1.0)]
    check("two slow taps are not a double tap", slow.map { d.feed($0.0, at: $0.1) }.allSatisfy { !$0 })
    check("every jump letter names one tab", Set(JumpLetters.table.map(\.0)).count == JumpLetters.table.count)

    // panel-wide keys
    func ev(_ code: Int, _ mods: NSEvent.ModifierFlags = [], _ ch: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: UInt16(code))!
    }
    let tabs = ["usage", "notes", "timers", "home"], spaces = [["usage"], ["timers", "notes"], ["home"]]
    func mv(_ e: NSEvent, _ cur: String = "notes", jumping: Bool = false) -> PanelNav.Move? {
        PanelNav.move(e, current: cur, tabs: tabs, spaces: spaces, jumping: jumping)
    }
    check("⌃Tab and ⌃⇧Tab walk the tabs and wrap", mv(ev(kVK_Tab, .control, "\t")) == .tab("timers")
          && mv(ev(kVK_Tab, [.control, .shift], "\t"), "usage") == .tab("home"))
    check("⌘2 opens a space on its last-used tab", mv(ev(kVK_ANSI_2, .command, "2"), "usage") == .tab("timers"))
    check("⌘2 inside that space stays put", mv(ev(kVK_ANSI_2, .command, "2"), "notes") == .tab("notes"))
    check("after ⌘⌘, a letter jumps to its tab", mv(ev(kVK_ANSI_B, [], "b"), jumping: true) == .tab("home"))
    check("after ⌘⌘, Escape just stops listening", mv(ev(kVK_Escape, [], "\u{1b}"), jumping: true) == PanelNav.Move.none)
    check("without ⌘⌘, letters are left to the tab", mv(ev(kVK_ANSI_B, [], "b")) == nil)
    PanelKeys.shared.jumping = false

    // any other tab: rows in reading order, each acted on by what it offers
    let kr = KeyRows()
    var log: [String] = []
    var open = false
    kr.set("b", frame: CGRect(x: 0, y: 40, width: 10, height: 10), actions: RowKeyActions(primary: { log.append("b") }))
    kr.set("a", frame: CGRect(x: 0, y: 10, width: 10, height: 10), actions: RowKeyActions(toggle: { log.append("a-flip") }))
    kr.set("c", frame: CGRect(x: 0, y: 70, width: 10, height: 10),
           actions: RowKeyActions(isOpen: { open }, setOpen: { open = $0 }))
    _ = kr.handle(.down)
    check("↓ on a tab with no row chosen picks the top row", kr.focused == "a")
    _ = kr.handle(.space)
    check("Space flips the row's switch", log == ["a-flip"])
    _ = kr.handle(.down); _ = kr.handle(.enter)
    check("Return does what a click does", log.last == "b")
    _ = kr.handle(.down); _ = kr.handle(.right)
    check("→ opens a row with children, ← closes it", open && { _ = kr.handle(.left); return !open }())
    check("Escape lets go of the row, then is the panel's", kr.handle(.escape) && kr.focused == nil && !kr.handle(.escape))
    var stepped = 0
    kr.set("s", frame: CGRect(x: 0, y: 100, width: 10, height: 10), actions: RowKeyActions(step: { stepped += $0 }))
    kr.focused = "s"; _ = kr.handle(.right); _ = kr.handle(.right); _ = kr.handle(.left)
    check("← and → step a slider or a choice", stepped == 1)

    // bulbs and timers
    let rows = ["x", "y"]
    check("Escape in the new timer's label hands the keyboard to the first timer",
          RowKeys.move(.field, .escape, ids: rows, hasField: true, typing: true) == (.row("x"), true))
    check("typing in a label keeps the arrows", RowKeys.move(.field, .down, ids: rows, hasField: true, typing: true).1 == false)
    check("↑ from the first timer goes back to the label",
          RowKeys.move(.row("x"), .up, ids: rows, hasField: true, typing: false) == (.field, true))
    check("↑ from the first bulb stays on it", RowKeys.move(.row("x"), .up, ids: rows, hasField: false, typing: false) == (.row("x"), true))
    check("↓ walks the rows and stops at the end",
          RowKeys.move(RowKeys.move(.row("x"), .down, ids: rows, hasField: false, typing: false).0, .down, ids: rows, hasField: false, typing: false).0 == .row("y"))
    check("a row's own keys are left to its tab", RowKeys.move(.row("x"), .space, ids: rows, hasField: false, typing: false).1 == false)
    return lines
}
