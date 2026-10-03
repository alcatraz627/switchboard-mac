// KeyDrive.swift
// Drives the real Notes views with key events, in a window of their own, so
// the keyboard path can be checked end to end without a person at the keys:
// the same router the panel uses, then the window's own text handling. Runs
// on the scratch notes folder the caller points SWITCHBOARD_STATE at, and
// saves a picture of the window at each step.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class KeyDrive {
    private let out: String
    private let space = "drive"
    private var window: NSWindow!
    private var lines: [String] = []
    private var steps: [(String, () -> Void)] = []
    private var shot = 0
    private var trace: Any?
    private var nav: NotesNav { NotesNav.forSpace(space) }
    private let store = NotesStore.shared

    init(out: String) { self.out = out }

    func run() {
        guard UserDefaults.standard.string(forKey: NotesStore.folderKey)?.isEmpty ?? true else {
            print("FAIL a notes folder is chosen in Settings; the drive only runs on a scratch state folder"); exit(1)
        }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // timers of the drive's own, under a key of their own, read when the store first loads
        TimerStore.key = "switchboard.timers.countdowns.drive"
        let seed = [SBTimer(label: "Tea", color: "green", start: Date(), fireAt: Date().addingTimeInterval(600)),
                    SBTimer(label: "Bread", color: "orange", start: Date(), fireAt: Date().addingTimeInterval(900))]
        UserDefaults.standard.set(try? JSONEncoder().encode(seed), forKey: TimerStore.key)
        store.load()
        _ = store.add(title: "Second", body: "line two", color: "green")
        _ = store.add(title: "First", body: "the body\nsecond line", color: nil)

        let root = ScaledRoot {
            VStack(spacing: 0) {
                NoteCompose(notes: NotesStore.shared, space: "drive")
                ScrollView { NotesTabView(notes: NotesStore.shared) }.frame(height: 520)
            }
            .frame(width: PT.width)
            .environment(\.panelSpace, "drive")
            .background(Color(nsColor: .windowBackgroundColor))
        }
        let host = NSHostingView(rootView: AnyView(root))
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: PT.width, height: 640),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        plan()
        if ProcessInfo.processInfo.environment["KEYDRIVE_TRACE"] != nil {
            trace = nav.$focus.sink { [weak self] f in
                let r = (self?.window.firstResponder).map { String(describing: Swift.type(of: $0)) } ?? "-"
                FileHandle.standardError.write("  focus → \(f)   (responder now \(r))\n".data(using: .utf8)!)
            }
        }
        // the views draw and hand out the keyboard first, as they would in the panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.next(0) }
    }

    // ── the steps ──

    private func plan() {
        step("the new note has the keyboard when the tab opens") {
            self.check(self.nav.focus == .compose, "\(self.nav.focus)")
            self.check(self.editing?.isEditable == true, "no editable field has the keyboard")
        }
        step("typing goes into the new note's title") {
            self.type("Alpha")
        }
        step("⌘↩ saves it and keeps typing in the saved note, same field, same place") {
            self.check(self.nav.draftTitle == "Alpha", self.nav.draftTitle)
            self.key(kVK_Return, [.command])
        }
        step("the saved note is open for typing") {
            let n = self.store.live.first { $0.title == "Alpha" }
            self.check(n != nil, "no note titled Alpha")
            self.check(self.nav.focus == .open(n?.id ?? "", .title, typing: true), "\(self.nav.focus)")
            self.check(self.nav.draftTitle.isEmpty, "the new-note box still holds \(self.nav.draftTitle)")
            self.check(self.editing?.string == "Alpha", self.editing?.string ?? "no field")
            self.check(self.editing?.selectedRange().location == 5, "cursor at \(self.editing?.selectedRange().location ?? -1)")
            self.type(" more")
        }
        step("Escape stops typing, saves, and leaves the note open to read") {
            self.key(kVK_Escape)
        }
        step("reading: the title holds the keyboard, read-only") {
            let n = self.store.live.first { $0.title.hasPrefix("Alpha") }
            self.check(n?.title == "Alpha more", n?.title ?? "nil")
            self.check(self.nav.focus == .open(n?.id ?? "", .title, typing: false), "\(self.nav.focus)")
            self.check(self.responder?.isEditable == false,
                       "editable field \"\(self.responder?.string ?? "")\", field editor \(self.responder?.isFieldEditor ?? false)")
            self.key(kVK_DownArrow)
        }
        step("↓ moves to the body; ⌘A selects all of it") {
            if case .open(_, .body, typing: false) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.key(kVK_ANSI_A, [.command])
        }
        step("the whole body is selected") {
            let tv = self.responder
            self.check(tv != nil && tv?.selectedRange().length == (tv?.string as NSString?)?.length, "selected \(tv?.selectedRange().length ?? -1)")
            self.key(kVK_LeftArrow)
        }
        step("← closes the note and leaves the ring on it") {
            if case .row = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.check(self.responder == nil, "a field still has the keyboard")
            self.key(kVK_DownArrow)
        }
        step("↓ moves to the next note") {
            let ids = self.nav.visible(self.store.live).map(\.id)
            self.check(self.nav.focus == .row(ids[1]), "\(self.nav.focus) of \(ids)")
            self.key(kVK_UpArrow); self.key(kVK_UpArrow)
        }
        step("↑ past the first note reaches the colour filter") {
            self.check(self.nav.focus == .filter(0), "\(self.nav.focus)")
            for _ in 0..<4 { self.key(kVK_RightArrow) }
        }
        step("Space on the green dot shows only green notes") {
            self.check(self.nav.focus == .filter(4), "\(self.nav.focus)")
            self.key(kVK_Space)
        }
        step("only the green note is listed") {
            self.check(self.nav.visible(self.store.live).map(\.title) == ["Second"], "\(self.nav.visible(self.store.live).map(\.title))")
            self.key(kVK_LeftArrow); self.key(kVK_LeftArrow); self.key(kVK_LeftArrow); self.key(kVK_LeftArrow)
            self.key(kVK_Space)
        }
        step("All clears it; ↑ goes to search, ↑ again to the new note") {
            self.check(self.nav.filter.isEmpty, "\(self.nav.filter)")
            self.key(kVK_UpArrow); self.key(kVK_UpArrow)
        }
        step("the new note has the keyboard again; Escape keeps a draft") {
            self.check(self.nav.focus == .compose, "\(self.nav.focus)")
            self.type("draft kept")
            self.key(kVK_Escape)
        }
        step("the draft is still there and the list has the keyboard") {
            self.check(self.nav.draftTitle == "draft kept", self.nav.draftTitle)
            if case .row = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.key(kVK_RightArrow); self.key(kVK_RightArrow)
        }
        step("→ → opens the note and starts typing at the end of the title") {
            if case .open(_, .title, typing: true) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            let tv = self.editing
            self.check(tv?.selectedRange().location == (tv?.string as NSString?)?.length, "cursor at \(tv?.selectedRange().location ?? -1)")
            self.key(kVK_Tab)
        }
        step("Tab from the title goes on typing in the body") {
            if case .open(_, .body, typing: true) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.check(self.editing != nil, "the body does not have the keyboard")
            self.key(kVK_Tab)
        }
        step("Tab from the body types in the tags") {
            if case .open(_, .tags, typing: true) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.check(self.editing?.isFieldEditor == true, "the tags box does not have the keyboard")
            self.type("ops")
            self.key(kVK_Tab)
        }
        step("Tab from the tags reaches the expiry, saved, no longer typing") {
            if case .open(_, .expiry, typing: false) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.check(self.editing == nil, "a field still takes typing")
            self.key(kVK_Return)
        }
        step("Return on the expiry opens its picker") {
            self.check(self.nav.picker == .expiry, "\(String(describing: self.nav.picker))")
            // the picker is its own window and takes the keys; Escape there closes it, as this does
            self.nav.picker = nil
        }
        step("the picker closed, the keyboard is back on the expiry") {
            if case .open(_, .expiry, typing: false) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.check(self.editing == nil, "a field took the keyboard: \(String(describing: self.responder.map { Swift.type(of: $0) }))")
            self.key(kVK_Tab); self.key(kVK_Tab)
        }
        step("Tab Tab reaches the colour") {
            if case .open(_, .color, typing: false) = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.key(kVK_ANSI_3, chars: "3")
        }
        step("a digit on the colour sets it; the tags were saved") {
            let n = self.store.live.first { $0.title == "Alpha more" }
            self.check(n?.color == "yellow", n?.color ?? "none")
            self.check(n?.tags == ["ops"], "\(n?.tags ?? [])")
            self.key(kVK_Escape)
            self.key(kVK_ANSI_Slash, chars: "/")
        }
        step("/ goes to search; the colour set before Escape is still there") {
            self.check(self.store.live.first { $0.title == "Alpha more" }?.color == "yellow",
                       self.store.live.first { $0.title == "Alpha more" }?.color ?? "none")
            self.check(self.nav.focus == .search, "\(self.nav.focus)")
            self.check(self.editing?.isFieldEditor == true, "the search box does not have the keyboard")
            self.type("two")
        }
        step("only the matching note is listed") {
            self.check(self.nav.visible(self.store.live).map(\.title) == ["Second"], "\(self.nav.visible(self.store.live).map(\.title))")
            self.key(kVK_Escape)
        }
        step("Escape empties the search and stays in it") {
            self.check(self.nav.query.isEmpty && self.nav.focus == .search, "query \(self.nav.query), \(self.nav.focus)")
            self.key(kVK_Escape)
        }
        step("Escape again goes to the first note") {
            if case .row = self.nav.focus { self.check(true) } else { self.check(false, "\(self.nav.focus)") }
            self.showTimers()
        }

        // Timers, on a timer list of the drive's own
        step("the new timer's label has the keyboard") {
            self.tab = "timers"
            self.check(self.editing != nil, "no editable field")
            self.key(kVK_Escape)
        }
        step("Escape hands the keyboard to the first timer") {
            self.check(self.rows.focus == .row(self.timerIDs[0]), "\(self.rows.focus)")
            self.check(self.responder == nil, "a field still has the keyboard")
            self.firedAt = TimerStore.shared.timers.first?.fireAt
            self.key(kVK_ANSI_Equal, chars: "+")
        }
        step("+ adds a minute to it") {
            let now = TimerStore.shared.timers.first { $0.id == self.timerIDs[0] }?.fireAt
            self.check(now.map { Int($0.timeIntervalSince(self.firedAt ?? $0)) } == 60, "\(String(describing: now)) vs \(String(describing: self.firedAt))")
            self.key(kVK_DownArrow)
            self.key(kVK_Return)
        }
        step("Return on the second timer renames it") {
            self.check(self.rows.renaming == self.timerIDs[1], "\(String(describing: self.rows.renaming))")
            self.check(self.editing != nil, "no editable field")
            self.editing?.selectAll(nil)
            self.type("Pasta")
            self.key(kVK_Return)
        }
        step("Return saves the name and the keyboard stays on the timer") {
            let t = TimerStore.shared.timers.first { $0.id == self.timerIDs[1] }
            self.check(t?.label == "Pasta", t?.label ?? "nil")
            self.check(self.rows.renaming == nil && self.rows.focus == .row(self.timerIDs[1]), "\(self.rows.focus), renaming \(String(describing: self.rows.renaming))")
            self.key(kVK_Delete)
        }
        step("⌫ clears it and the keyboard moves to the one before") {
            self.check(!TimerStore.shared.timers.contains { $0.id == self.timerIDs[1] }, "still listed")
            self.check(self.rows.focus == .row(self.timerIDs[0]), "\(self.rows.focus)")
            self.key(kVK_UpArrow)
        }
        step("↑ from the first timer goes back to the label") {
            self.check(self.rows.focus == .field, "\(self.rows.focus)")
            self.check(self.editing != nil, "the label does not have the keyboard")
            self.showDeskNotes()
        }
        step("a pinned Notes tab carries its new-note box and search") {
            let fields = self.textFields(in: self.window.contentView)
            self.check(fields >= 2, "\(fields) text fields drawn")
            self.showSharedRows()
        }
        // any other tab: the shared rows, made up for the drive so no real setting changes
        step("↓ on a tab of shared rows reaches the first row") {
            self.tab = "machine"
            self.key(kVK_DownArrow)
        }
        step("the first row has the keyboard; Return does what its click does") {
            self.check(KeyRows.forSpace(self.space).focused?.contains("Run me") == true, "\(String(describing: KeyRows.forSpace(self.space).focused))")
            self.key(kVK_Return)
        }
        step("its action ran; ↓ then → opens the row with children") {
            self.check(self.log == ["run"], "\(self.log)")
            self.key(kVK_DownArrow); self.key(kVK_RightArrow)
        }
        step("the children show and take the keyboard in turn") {
            let child = KeyRows.forSpace(self.space).ordered.contains { $0.contains("A child") }
            self.check(child, "\(KeyRows.forSpace(self.space).ordered)")
            self.key(kVK_DownArrow); self.key(kVK_DownArrow); self.key(kVK_RightArrow)
        }
        step("→ on a choice row picks the next choice") {
            self.check(self.chosen == 1, "chosen \(self.chosen)")
        }
    }

    private var tab = "notes"
    private var log: [String] = []
    private var chosen = 0

    /// Three shared rows as a tab draws them: one with an action, one with children, one with choices.
    private func showSharedRows() {
        window.makeFirstResponder(nil)
        var run = SystemRow(label: "Run me", state: .ok, note: "", tip: "", action: { [weak self] in self?.log.append("run") })
        run.buttonLabel = "Run"
        var parent = SystemRow(label: "Has children", state: .ok, note: "", tip: "")
        parent.children = [SystemRow(label: "A child", state: .ok, note: "child", tip: "")]
        var pick = SystemRow(label: "Pick one", state: .ok, note: "", tip: "")
        pick.choices = ["One", "Two", "Three"]; pick.selected = 0
        pick.onChoose = { [weak self] i in self?.chosen = i }
        let store = PolicyStore()
        (window.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(ScaledRoot {
            VStack(spacing: 0) {
                SystemRowView(row: run, store: store)
                SystemRowView(row: parent, store: store)
                SystemRowView(row: pick, store: store)
            }
            .frame(width: PT.width)
            .coordinateSpace(name: "drive")
            .environment(\.panelSpace, "drive")
            .background(Color(nsColor: .windowBackgroundColor))
        })
    }
    private var firedAt: Date?
    private var timerIDs: [String] = []
    private var rows: RowNav { RowNav.forSpace(space, "timers") }

    /// The desk panel's own view around a Notes tab, as a pinned Notes window draws it.
    private func showDeskNotes() {
        window.makeFirstResponder(nil)
        let c = SwitchboardConcern(id: "notes", title: "Notes", subtitle: "", icon: "note.text", footer: "", footerIcon: "doc.text",
                                   content: AnyView(NotesTabView(notes: NotesStore.shared)), pinned: AnyView(NotesTop()))
        (window.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(ScaledRoot {
            DeskTab(concern: c, space: "desk-tab-notes").background(Color(nsColor: .windowBackgroundColor))
        })
    }

    /// Text inputs drawn in a view tree: the new-note box and the search box each count once or more.
    private func textFields(in v: NSView?) -> Int {
        guard let v else { return 0 }
        return (v is NSTextView || v is NSTextField ? 1 : 0) + v.subviews.reduce(0) { $0 + textFields(in: $1) }
    }

    private func showTimers() {
        let ts = TimerStore.shared
        ts.chimeAloud = false
        timerIDs = ts.timers.map(\.id)
        window.makeFirstResponder(nil)
        (window.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(ScaledRoot {
            ScrollView { TimersTabView(timers: TimerStore.shared) }.frame(height: 520)
                .frame(width: PT.width).environment(\.panelSpace, "drive")
                .background(Color(nsColor: .windowBackgroundColor))
        })
    }

    // ── machinery ──

    private func step(_ name: String, _ body: @escaping () -> Void) { steps.append((name, body)) }

    private var current = ""
    private func next(_ i: Int) {
        guard i < steps.count else { finish(); return }
        current = steps[i].0
        if trace != nil { FileHandle.standardError.write("step: \(current)\n".data(using: .utf8)!) }
        steps[i].1()
        // the views settle, then the picture and the next step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.snap()
            self.next(i + 1)
        }
    }

    private func check(_ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(current)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }

    private func finish() {
        UserDefaults.standard.removeObject(forKey: TimerStore.key)
        print(lines.joined(separator: "\n"))
        exit(lines.contains { $0.hasPrefix("FAIL") } ? 1 : 0)
    }

    private var responder: NSTextView? { window.firstResponder as? NSTextView }
    private var editing: NSTextView? { responder.flatMap { $0.isEditable ? $0 : nil } }

    /// A key as the panel would get it: the router first, then the window.
    private func key(_ code: Int, _ mods: NSEvent.ModifierFlags = [], chars: String? = nil) {
        let c = chars ?? Self.char(code)
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: c,
                                       charactersIgnoringModifiers: c, isARepeat: false, keyCode: UInt16(code)) else { return }
        if !KeyRouter.handle(e, space: space, tab: tab) { window.sendEvent(e) }
    }

    private func type(_ s: String) {
        for ch in s { responder?.insertText(String(ch), replacementRange: responder?.selectedRange() ?? NSRange(location: 0, length: 0)) }
    }

    private static func char(_ code: Int) -> String {
        switch code {
        case kVK_Return: return "\r"
        case kVK_Escape: return "\u{1b}"
        case kVK_Space: return " "
        case kVK_ANSI_A: return "a"
        case kVK_Tab: return "\t"
        case kVK_UpArrow: return String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        case kVK_DownArrow: return String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
        case kVK_LeftArrow: return String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)
        case kVK_RightArrow: return String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!)
        default: return ""
        }
    }

    private func snap() {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        shot += 1
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/step-\(String(format: "%02d", shot)).png"))
    }
}
