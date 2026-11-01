// NotesCaptureProbe.swift
// Headless checks for the capture chords: the key table, and where each chord puts the keyboard.

import Foundation

func probeCapture() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    func day(_ d: Int) -> Date { Date(timeIntervalSince1970: Double(d) * 86400) }
    let keys = HotKeys.chords.map { "\($0.key)/\($0.mods)" }
    check("no two chords share the same keys", Set(keys).count == keys.count, keys.joined(separator: " "))
    check("the capture chords are ⌥⇧N and ⌥⇧L", HotKeys.chords.contains { $0.tab == "capture:new" && $0.label == "⌥⇧N" }
          && HotKeys.chords.contains { $0.tab == "capture:last" && $0.label == "⌥⇧L" })
    check("capture chords are on until switched off", HotKeys.captureOn)
    let older = Note(id: "a", title: "A", body: "x", tags: [], created: day(100))
    let newer = Note(id: "b", title: "B", body: "y", tags: [], created: day(200))
    check("the new-note chord goes to the new-note box", PolicyStatusController.captureTarget(last: false, notes: [older, newer]) == .compose)
    check("the last-note chord with no notes also goes to the new-note box", PolicyStatusController.captureTarget(last: true, notes: []) == .compose)
    let t = PolicyStatusController.captureTarget(last: true, notes: [older, newer])
    check("the last-note chord opens a note for typing in its body", { if case .open(_, .body, true) = t { return true } else { return false } }(), "\(t)")
    check("Settings says so when another app holds a capture chord", HotKeys.captureNote(on: true, failed: ["⌥⇧N"]).contains("another app holds ⌥⇧N")
          && HotKeys.captureNote(on: true, failed: []) == "on: from any app, Esc goes back" && HotKeys.captureNote(on: false, failed: ["⌥⇧N"]) == "off"
          && !HotKeys.captureNote(on: true, failed: ["⌥Space"]).contains("not working"))
    // the inbox by keyboard
    let c = NotesKeys.Context(ids: ["n1", "n2"], inbox: ["i1", "i2", "i3"])
    func step(_ f: NoteFocus, _ k: Key) -> (NoteFocus, [NoteEffect], Bool) { NotesKeys.reduce(f, k, c) }
    check("I steps from a note into the first inbox item", step(.row("n1"), .char("i")).0 == .inbox("i1"))
    check("I does nothing when the inbox is empty", NotesKeys.reduce(.row("n1"), .char("i"), NotesKeys.Context(ids: ["n1"])).0 == .row("n1"))
    check("↓ and ↑ walk the inbox, ↑ from the first leaves it, ↓ from the last goes to the list",
          step(.inbox("i1"), .down).0 == .inbox("i2") && step(.inbox("i2"), .up).0 == .inbox("i1") && step(.inbox("i1"), .up).0 == .none
          && step(.inbox("i3"), .down).0 == .row("n1"))
    check("K keeps, D puts away, L sets it for later, Return opens",
          step(.inbox("i2"), .char("k")).1 == [.inboxKeep("i2")] && step(.inbox("i2"), .char("d")).1 == [.inboxDone("i2")]
          && step(.inbox("i2"), .char("l")).1 == [.inboxLater("i2")] && step(.inbox("i2"), .enter).1 == [.inboxOpen("i2")])
    check("Esc leaves the inbox", step(.inbox("i2"), .escape).0 == .none)
    check("typing in a field never steps into the inbox", NotesKeys.reduce(.compose, .char("i"), NotesKeys.Context(ids: ["n1"], typing: true, inbox: ["i1"])).0 == .compose)
    return lines
}
