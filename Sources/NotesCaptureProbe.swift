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
    return lines
}
