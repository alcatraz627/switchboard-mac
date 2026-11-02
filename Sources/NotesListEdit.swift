// NotesListEdit.swift
// How a note's text behaves while it is typed: Return carries a list on to its next item, Tab indents the lines
// the selection touches, and a marker typed over the one Return just put there is folded into it. Pure text maths
// on a string and a selection, so the probe checks it without a window. The same rules the Chrome extension's
// note editor keeps, so a list feels the same in both.

import Foundation

enum ListEdit {
    /// The marker Return just put on a new line: where the line starts and what was put there.
    struct AutoMarker: Equatable {
        var lineStart: Int
        var prefix: String
    }

    private static let item = try! NSRegularExpression(pattern: "^(\\s*)([-*+]|\\d+[.)])\\s(\\[[ xX]\\]\\s)?(.*)$")
    private static let bareMarker = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d+[.)])\\s(\\[[ xX]\\]\\s)?$")
    private static let typedMarker = try! NSRegularExpression(pattern: "^([-*+]|\\d+[.)])\\s(\\[[ xX]\\]\\s)?")

    private static func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
    }

    /// The lines a selection touches, without the newline that ends the last one.
    private static func lines(_ text: String, _ sel: NSRange) -> NSRange {
        let ns = text as NSString
        var s = sel
        if s.length > 0, s.upperBound <= ns.length, ns.character(at: s.upperBound - 1) == 10 { s.length -= 1 }
        var r = ns.lineRange(for: s)
        if r.length > 0, ns.character(at: r.upperBound - 1) == 10 { r.length -= 1 }
        return r
    }

    /// Tab puts two spaces in front of each line the selection touches; Shift-Tab takes them off again.
    static func indent(_ text: String, _ sel: NSRange, outdent: Bool, unit: String = "  ") -> LineEdit.Edit {
        let ns = text as NSString
        let span = lines(text, sel)
        let parts = ns.substring(with: span).components(separatedBy: "\n")
        var first = 0, total = 0
        let changed = parts.enumerated().map { i, l -> String in
            var line = l, d: Int
            if outdent {
                let n = line.hasPrefix(unit) ? unit.count : (line.hasPrefix(" ") ? 1 : 0)
                d = -n; line = String(line.dropFirst(n))
            } else { line = unit + line; d = unit.count }
            if i == 0 { first = d }
            total += d
            return line
        }
        let start = max(span.location, sel.location + first), end = max(span.location, sel.upperBound + total)
        return LineEdit.Edit(range: span, replacement: changed.joined(separator: "\n"), selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// Return inside a list item starts the next one (a number counts up, a task box comes back empty); Return on
    /// an empty item ends the list and leaves one blank line under it. Nil when the cursor is not in a list item.
    static func continueList(_ text: String, _ sel: NSRange) -> LineEdit.Edit? {
        let ns = text as NSString
        let from = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let line = ns.substring(with: NSRange(location: from, length: sel.location - from))
        guard let m = item.firstMatch(in: line, range: whole(line)), let marker = group(m, 2, in: line) else { return nil }
        let indent = group(m, 1, in: line) ?? "", box = group(m, 3, in: line), rest = group(m, 4, in: line) ?? ""
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            let before = ns.substring(to: from)
            let gap = from == 0 || before.hasSuffix("\n\n") ? "" : "\n"
            var below = ns.substring(from: min(ns.length, sel.upperBound))
            while below.hasPrefix("\n") { below.removeFirst() }
            let tail = gap + (below.isEmpty ? "" : (gap.isEmpty ? "\n" : "") + below)
            let at = below.isEmpty ? from + gap.count : from
            return LineEdit.Edit(range: NSRange(location: from, length: ns.length - from), replacement: tail, selection: NSRange(location: at, length: 0))
        }
        var next = marker
        if let n = Int(marker.dropLast()), let last = marker.last { next = "\(n + 1)\(last)" }
        let ins = "\n" + indent + next + " " + (box != nil ? "[ ] " : "")
        return LineEdit.Edit(range: sel, replacement: ins, selection: NSRange(location: sel.location + (ins as NSString).length, length: 0))
    }

    /// The marker Return just put on the line the cursor is on, for `absorbTyped` to watch; nil when the line holds none.
    static func autoMarker(_ text: String, caret: Int) -> AutoMarker? {
        let ns = text as NSString
        let start = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        guard start > 0, bareMarker.firstMatch(in: prefix, range: whole(prefix)) != nil else { return nil }
        return AutoMarker(lineStart: start, prefix: prefix)
    }

    /// Someone who types the marker themselves right after Return put one there would get it twice ("- - ", "2. 2. ").
    /// Once what they typed after the automatic marker is a whole marker it is folded into it: the automatic one
    /// stays, unless the typed one adds a task box, which then wins. Nil while nothing is repeated.
    static func absorbTyped(_ text: String, caret: Int, auto: AutoMarker) -> LineEdit.Edit? {
        let ns = text as NSString
        let end = auto.lineStart + (auto.prefix as NSString).length
        guard caret >= end, ns.length >= end, ns.substring(with: NSRange(location: auto.lineStart, length: end - auto.lineStart)) == auto.prefix else { return nil }
        let typed = ns.substring(with: NSRange(location: end, length: caret - end))
        guard let m = typedMarker.firstMatch(in: typed, range: whole(typed)) else { return nil }
        let rest = (typed as NSString).substring(from: m.range.length)
        let typedBox = group(m, 2, in: typed) != nil
        let autoBox = auto.prefix.range(of: "\\[[ xX]\\]\\s$", options: .regularExpression) != nil
        // the box may still be coming ("- " then "[ ] "), so wait for the next key
        if !typedBox, autoBox, rest.range(of: "^(\\[[ xX]?\\]?)?$", options: .regularExpression) != nil { return nil }
        let ind = String(auto.prefix.prefix(while: { $0 == " " || $0 == "\t" }))
        let keep = (typedBox ? ind + (typed as NSString).substring(to: m.range.length) : auto.prefix) + rest
        let at = auto.lineStart + (keep as NSString).length
        return LineEdit.Edit(range: NSRange(location: auto.lineStart, length: caret - auto.lineStart), replacement: keep, selection: NSRange(location: at, length: 0))
    }
}

func probeListEdit() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    func run(_ text: String, _ e: LineEdit.Edit?) -> (String, NSRange)? {
        e.map { ((text as NSString).replacingCharacters(in: $0.range, with: $0.replacement), $0.selection) }
    }
    func at(_ s: String) -> NSRange { NSRange(location: (s as NSString).length, length: 0) }

    let dash = run("- milk", ListEdit.continueList("- milk", at("- milk")))
    check("Return after a dash item starts the next dash", dash?.0 == "- milk\n- " && dash?.1 == at("- milk\n- "), "\(String(describing: dash))")
    let num = run("1. milk", ListEdit.continueList("1. milk", at("1. milk")))
    check("a numbered item counts up", num?.0 == "1. milk\n2. ", "\(String(describing: num))")
    let paren = run("9) milk", ListEdit.continueList("9) milk", at("9) milk")))
    check("a number with a bracket keeps its bracket and counts up", paren?.0 == "9) milk\n10) ", "\(String(describing: paren))")
    let task = run("- [x] milk", ListEdit.continueList("- [x] milk", at("- [x] milk")))
    check("a done task is followed by an empty box", task?.0 == "- [x] milk\n- [ ] ", "\(String(describing: task))")
    let nested = run("  - milk", ListEdit.continueList("  - milk", at("  - milk")))
    check("an indented item keeps its indent", nested?.0 == "  - milk\n  - ", "\(String(describing: nested))")
    let end = run("- milk\n- ", ListEdit.continueList("- milk\n- ", at("- milk\n- ")))
    check("Return on an empty item ends the list with a blank line under it", end?.0 == "- milk\n\n" && end?.1 == at("- milk\n\n"), "\(String(describing: end))")
    let mid = "- milk\n- \nafter"
    let endMid = run(mid, ListEdit.continueList(mid, NSRange(location: 9, length: 0)))
    check("text under the list keeps one blank line above it", endMid?.0 == "- milk\n\nafter" && endMid?.1.location == 7, "\(String(describing: endMid))")
    check("a line that is not a list item is left to Return", ListEdit.continueList("just words", at("just words")) == nil
          && ListEdit.continueList("-milk", at("-milk")) == nil)
    let split = run("- milk and eggs", ListEdit.continueList("- milk and eggs", NSRange(location: 6, length: 0)))
    check("Return in the middle of an item splits it", split?.0 == "- milk\n-  and eggs", "\(String(describing: split))")

    let ind = run("a\nb\nc", ListEdit.indent("a\nb\nc", NSRange(location: 0, length: 3), outdent: false))
    check("Tab indents every line the selection touches", ind?.0 == "  a\n  b\nc" && ind?.1 == NSRange(location: 2, length: 5), "\(String(describing: ind))")
    let out = run("  a\n b\nc", ListEdit.indent("  a\n b\nc", NSRange(location: 0, length: 7), outdent: true))
    check("Shift-Tab takes two spaces, or one, off", out?.0 == "a\nb\nc", "\(String(describing: out))")
    let caret = run("a", ListEdit.indent("a", NSRange(location: 1, length: 0), outdent: false))
    check("Tab with just a caret indents its line and the caret goes with it", caret?.0 == "  a" && caret?.1 == NSRange(location: 3, length: 0), "\(String(describing: caret))")
    let ends = run("a\nb\n", ListEdit.indent("a\nb\n", NSRange(location: 0, length: 2), outdent: false))
    check("a selection that ends at the start of the next line does not take that line", ends?.0 == "  a\nb\n", "\(String(describing: ends))")

    let autoText = "- milk\n- "
    let auto = ListEdit.autoMarker(autoText, caret: (autoText as NSString).length)
    check("the marker Return put is remembered", auto == ListEdit.AutoMarker(lineStart: 7, prefix: "- "), "\(String(describing: auto))")
    check("a first line is never an automatic marker", ListEdit.autoMarker("- ", caret: 2) == nil)
    if let a = auto {
        let typed = autoText + "- "
        let fixed = run(typed, ListEdit.absorbTyped(typed, caret: (typed as NSString).length, auto: a))
        check("typing the marker over the automatic one does not double it", fixed?.0 == "- milk\n- ", "\(String(describing: fixed))")
        check("typing other words leaves it alone", ListEdit.absorbTyped(autoText + "e", caret: (autoText as NSString).length + 1, auto: a) == nil)
    } else { check("typing the marker over the automatic one does not double it", false, "no marker") }
    let boxText = "- [x] a\n- [ ] "
    if let a = ListEdit.autoMarker(boxText, caret: (boxText as NSString).length) {
        let waiting = boxText + "- "
        check("with a task box already there, a typed dash waits for the box that may follow",
              ListEdit.absorbTyped(waiting, caret: (waiting as NSString).length, auto: a) == nil)
    } else { check("with a task box already there, a typed dash waits for the box that may follow", false, "no marker") }
    let plain = "- a\n- "
    if let a = ListEdit.autoMarker(plain, caret: (plain as NSString).length) {
        let boxed = plain + "- [ ] "
        let r = run(boxed, ListEdit.absorbTyped(boxed, caret: (boxed as NSString).length, auto: a))
        check("a typed marker with a task box wins over a plain automatic one", r?.0 == "- a\n- [ ] ", "\(String(describing: r))")
    } else { check("a typed marker with a task box wins over a plain automatic one", false, "no marker") }

    // the formatting added alongside
    let h1 = NoteFormat.heading("title", NSRange(location: 2, length: 0))
    let h2 = NoteFormat.heading(h1.text, h1.selection)
    let h3 = NoteFormat.heading(h2.text, h2.selection)
    let h4 = NoteFormat.heading(h3.text, h3.selection)
    check("Heading adds a level each press, then clears", h1.text == "# title" && h2.text == "## title" && h3.text == "### title" && h4.text == "title",
          [h1.text, h2.text, h3.text, h4.text].joined(separator: " | "))
    let h5 = NoteFormat.heading("a\nb", NSRange(location: 2, length: 0))
    check("Heading acts on the cursor's line only", h5.text == "a\n# b", h5.text)
    let ol = NoteFormat.orderedList("milk\neggs\nbread", NSRange(location: 0, length: 9))
    check("a numbered list numbers every line the selection touches", ol.text == "1. milk\n2. eggs\nbread", ol.text)
    check("and again takes the numbers off", NoteFormat.orderedList(ol.text, NSRange(location: 0, length: 15)).text == "milk\neggs\nbread")
    let q = NoteFormat.prefixLines("a\nb", NSRange(location: 0, length: 3), "> ")
    check("Quote puts > on each line", q.text == "> a\n> b", q.text)
    let st = NoteFormat.wrap("old news", NSRange(location: 0, length: 3), "~~")
    check("Strikethrough wraps the selection", st.text == "~~old~~ news", st.text)
    let t = NoteFormat.table("notes", NSRange(location: 5, length: 0))
    check("a table starts on its own line and its first heading is selected",
          t.text == "notes\n| Column 1 | Column 2 |\n| --- | --- |\n|   |   |\n|   |   |\n"
          && (t.text as NSString).substring(with: t.selection) == "Column 1", "\(t)")
    check("a table is read as one by the reader", MarkdownBody.blocks(t.text).contains { if case .table = $0 { return true }; return false })
    return lines
}
