// LineEdit.swift
// Moving and copying whole lines in the note editor, the way VS Code does: ⌥↑ and ⌥↓ move the lines the selection
// touches, ⌥⇧↑ and ⌥⇧↓ copy them above or below. Pure text maths, so it is checked without a window.

import AppKit

enum LineEdit {
    struct Edit: Equatable {
        /// The part of the text to replace, the replacement, and where the selection sits afterwards.
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    /// The lines a selection touches. A selection that ends at the very start of a line does not take that line.
    private static func block(_ ns: NSString, _ sel: NSRange) -> NSRange {
        var s = sel
        if s.length > 0, s.upperBound <= ns.length, s.upperBound > 0, ns.character(at: s.upperBound - 1) == 10 { s.length -= 1 }
        return ns.lineRange(for: s)
    }

    static func move(_ text: String, _ sel: NSRange, up: Bool) -> Edit? {
        let ns = text as NSString
        let b = block(ns, sel)
        if up {
            guard b.location > 0 else { return nil }
            let p = ns.lineRange(for: NSRange(location: b.location - 1, length: 0))
            var mine = ns.substring(with: b), prev = ns.substring(with: p)
            // the last line has no newline of its own: it takes the one the line above gives up
            if !mine.hasSuffix("\n") { mine += "\n"; prev = String(prev.dropLast()) }
            return Edit(range: NSRange(location: p.location, length: p.length + b.length), replacement: mine + prev,
                        selection: NSRange(location: sel.location - p.length, length: sel.length))
        }
        guard b.upperBound < ns.length else { return nil }
        let n = ns.lineRange(for: NSRange(location: b.upperBound, length: 0))
        var mine = ns.substring(with: b), next = ns.substring(with: n)
        if !next.hasSuffix("\n") { next += "\n"; mine = String(mine.dropLast()) }
        return Edit(range: NSRange(location: b.location, length: b.length + n.length), replacement: next + mine,
                    selection: NSRange(location: sel.location + (next as NSString).length, length: sel.length))
    }

    static func duplicate(_ text: String, _ sel: NSRange, up: Bool) -> Edit? {
        let ns = text as NSString
        let b = block(ns, sel)
        var mine = ns.substring(with: b)
        let hadNewline = mine.hasSuffix("\n")
        if !hadNewline { mine += "\n" }
        if up {
            // the copy goes above and the selection stays on the original, which is now the lower one
            return Edit(range: NSRange(location: b.location, length: 0), replacement: mine,
                        selection: NSRange(location: sel.location + (mine as NSString).length, length: sel.length))
        }
        if hadNewline {
            return Edit(range: NSRange(location: b.upperBound, length: 0), replacement: mine,
                        selection: NSRange(location: sel.location + b.length, length: sel.length))
        }
        // the last line: the copy needs a newline before it instead
        return Edit(range: NSRange(location: b.upperBound, length: 0), replacement: "\n" + String(mine.dropLast()),
                    selection: NSRange(location: sel.location + b.length + 1, length: sel.length))
    }

    /// Applies an edit to a text view as one undoable change.
    static func apply(_ e: Edit, to tv: NSTextView) {
        guard tv.shouldChangeText(in: e.range, replacementString: e.replacement) else { return }
        tv.textStorage?.replaceCharacters(in: e.range, with: e.replacement)
        tv.didChangeText()
        tv.setSelectedRange(e.selection)
    }
}

/// Checks of the line maths.
func probeLineEdit() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    func run(_ text: String, _ sel: NSRange, _ f: (String, NSRange) -> LineEdit.Edit?) -> (String, NSRange)? {
        guard let e = f(text, sel) else { return nil }
        return ((text as NSString).replacingCharacters(in: e.range, with: e.replacement), e.selection)
    }
    let t = "one\ntwo\nthree"
    let up = run(t, NSRange(location: 5, length: 0)) { LineEdit.move($0, $1, up: true) }
    check("a line moves up and the caret goes with it", up?.0 == "two\none\nthree" && up?.1 == NSRange(location: 1, length: 0), "\(String(describing: up))")
    let down = run(t, NSRange(location: 1, length: 0)) { LineEdit.move($0, $1, up: false) }
    check("a line moves down", down?.0 == "two\none\nthree" && down?.1 == NSRange(location: 5, length: 0), "\(String(describing: down))")
    let last = run(t, NSRange(location: 10, length: 0)) { LineEdit.move($0, $1, up: true) }
    check("the last line, with no newline, moves up and the text stays whole", last?.0 == "one\nthree\ntwo", "\(String(describing: last))")
    let intoLast = run(t, NSRange(location: 5, length: 0)) { LineEdit.move($0, $1, up: false) }
    check("a line moves down into the last place", intoLast?.0 == "one\nthree\ntwo", "\(String(describing: intoLast))")
    check("the first line cannot go up and the last cannot go down", run(t, NSRange(location: 0, length: 0)) { LineEdit.move($0, $1, up: true) } == nil
          && run(t, NSRange(location: 12, length: 0)) { LineEdit.move($0, $1, up: false) } == nil)
    let two = run("a\nb\nc\nd\n", NSRange(location: 2, length: 3)) { LineEdit.move($0, $1, up: true) }
    check("a selection over two lines moves both", two?.0 == "b\nc\na\nd\n", "\(String(describing: two))")
    let ends = run("a\nb\nc\n", NSRange(location: 0, length: 2)) { LineEdit.move($0, $1, up: false) }
    check("a selection that ends at the start of the next line does not take that line", ends?.0 == "b\na\nc\n", "\(String(describing: ends))")
    let dd = run("a\nb\n", NSRange(location: 0, length: 0)) { LineEdit.duplicate($0, $1, up: false) }
    check("copy down puts a second line below and the caret on it", dd?.0 == "a\na\nb\n" && dd?.1 == NSRange(location: 2, length: 0), "\(String(describing: dd))")
    let du = run("a\nb\n", NSRange(location: 2, length: 0)) { LineEdit.duplicate($0, $1, up: true) }
    check("copy up puts a second line above", du?.0 == "a\nb\nb\n", "\(String(describing: du))")
    let dl = run("a\nb", NSRange(location: 2, length: 0)) { LineEdit.duplicate($0, $1, up: false) }
    check("copying the last line down adds the newline it needs", dl?.0 == "a\nb\nb", "\(String(describing: dl))")
    return lines
}
