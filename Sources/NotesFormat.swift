// NotesFormat.swift
// The formatting line's edits on a note's text: wrap a selection, prefix the
// lines, make a link, drop in a picture. Plain functions on text and a
// selection, so the probe checks them without a window.

import AppKit
import Foundation

enum NoteFormat {
    enum Kind { case bold, italic, code, list, task, link, image }

    struct Edit: Equatable {
        let text: String
        let selection: NSRange
    }

    /// The mark around the selection, or an empty pair the cursor sits in; a selection already marked loses it.
    static func wrap(_ text: String, _ r: NSRange, _ mark: String) -> Edit {
        let s = text as NSString
        let sel = s.substring(with: r)
        let m = (mark as NSString).length
        if r.length > 0, sel.hasPrefix(mark), sel.hasSuffix(mark), (sel as NSString).length >= m * 2 {
            let inner = (sel as NSString).substring(with: NSRange(location: m, length: (sel as NSString).length - m * 2))
            return Edit(text: s.replacingCharacters(in: r, with: inner), selection: NSRange(location: r.location, length: (inner as NSString).length))
        }
        return Edit(text: s.replacingCharacters(in: r, with: mark + sel + mark), selection: NSRange(location: r.location + m, length: r.length))
    }

    /// Each line the selection touches gets the prefix; lines that all have it lose it.
    static func prefixLines(_ text: String, _ r: NSRange, _ prefix: String) -> Edit {
        let s = text as NSString
        let lines = s.lineRange(for: r)
        let block = s.substring(with: lines)
        let trailing = block.hasSuffix("\n")
        var parts = (trailing ? String(block.dropLast()) : block).components(separatedBy: "\n")
        let allHave = parts.allSatisfy { $0.hasPrefix(prefix) }
        parts = parts.map { allHave ? String($0.dropFirst(prefix.count)) : prefix + $0 }
        let out = parts.joined(separator: "\n") + (trailing ? "\n" : "")
        let kept = (out as NSString).length - (trailing ? 1 : 0)
        return Edit(text: s.replacingCharacters(in: lines, with: out), selection: NSRange(location: lines.location, length: kept))
    }

    /// `[selection](url)`: the clipboard's link when it holds one, else "url" left selected to type over.
    static func link(_ text: String, _ r: NSRange, clipboard: String?) -> Edit {
        let s = text as NSString
        let sel = r.length > 0 ? s.substring(with: r) : "link"
        let trimmed = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: String? = trimmed.hasPrefix("http") && !trimmed.contains(" ") ? trimmed : nil
        let piece = "[\(sel)](\(url ?? "url"))"
        let out = s.replacingCharacters(in: r, with: piece)
        if url == nil { return Edit(text: out, selection: NSRange(location: r.location + (sel as NSString).length + 3, length: 3)) }
        return Edit(text: out, selection: NSRange(location: r.location + (piece as NSString).length, length: 0))
    }

    /// `![name](path)` on a line of its own at the cursor.
    static func image(_ text: String, _ r: NSRange, path: String, name: String) -> Edit {
        let s = text as NSString
        let midLine = r.location > 0 && s.character(at: r.location - 1) != 10
        let piece = (midLine ? "\n" : "") + "![\(name)](\(path))\n"
        return Edit(text: s.replacingCharacters(in: r, with: piece), selection: NSRange(location: r.location + (piece as NSString).length, length: 0))
    }

    /// The pasted picture as a PNG under attachments/, named after the note and the moment; the path relative to the folder.
    static func savePNG(_ data: Data, noteID: String, dir: String, now: Date = Date()) -> String? {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let rel = "attachments/\(noteID)-\(f.string(from: now)).png"
        try? FileManager.default.createDirectory(atPath: dir + "/attachments", withIntermediateDirectories: true)
        guard (try? png.write(to: URL(fileURLWithPath: dir + "/" + rel))) != nil else { return nil }
        return rel
    }
}

func probeFormat() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    // A screenshot copied as a file puts its path on the clipboard too; the picture must win.
    let shot = NSTemporaryDirectory() + "sb-paste-\(getpid()).png"
    let tiny = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    try? tiny?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
    let pb = NSPasteboard(name: NSPasteboard.Name("sb-probe-\(getpid())"))
    pb.clearContents()
    pb.writeObjects([URL(fileURLWithPath: shot) as NSURL, shot as NSString])
    check("a copied picture file pastes as the picture, not its path", EditorTextView.pastedImageFile(pb).flatMap { NSBitmapImageRep(data: $0) } != nil)
    pb.clearContents()
    pb.writeObjects([URL(fileURLWithPath: NSTemporaryDirectory() + "notes.txt") as NSURL])
    check("a copied text file is left to paste as text", EditorTextView.pastedImageFile(pb) == nil)
    pb.releaseGlobally()
    try? FileManager.default.removeItem(atPath: shot)
    let w = NoteFormat.wrap("buy milk", NSRange(location: 4, length: 4), "**")
    check("bold wraps the selection and keeps it selected", w == .init(text: "buy **milk**", selection: NSRange(location: 6, length: 4)), "\(w)")
    let u = NoteFormat.wrap("buy **milk**", NSRange(location: 4, length: 8), "**")
    check("bold on a bold selection takes it off", u.text == "buy milk" && u.selection == NSRange(location: 4, length: 4), "\(u)")
    let e = NoteFormat.wrap("buy ", NSRange(location: 4, length: 0), "_")
    check("italic with nothing selected leaves the cursor between the marks", e == .init(text: "buy __", selection: NSRange(location: 5, length: 0)), "\(e)")
    let l = NoteFormat.prefixLines("milk\neggs\nbread", NSRange(location: 2, length: 6), "- ")
    check("list dashes every line the selection touches", l.text == "- milk\n- eggs\nbread", l.text)
    let l2 = NoteFormat.prefixLines(l.text, l.selection, "- ")
    check("list again takes the dashes off", l2.text == "milk\neggs\nbread", l2.text)
    let k = NoteFormat.link("see docs", NSRange(location: 4, length: 4), clipboard: "https://x.y/z")
    check("link uses the clipboard's address", k.text == "see [docs](https://x.y/z)", k.text)
    let k2 = NoteFormat.link("see docs", NSRange(location: 4, length: 4), clipboard: "not a link")
    check("without one, url is left selected to type over", k2.text == "see [docs](url)" && k2.selection == NSRange(location: 11, length: 3), "\(k2)")
    let i = NoteFormat.image("notes", NSRange(location: 5, length: 0), path: "attachments/a.png", name: "pasted")
    check("a picture goes on its own line", i.text == "notes\n![pasted](attachments/a.png)\n", i.text)
    let dir = NSTemporaryDirectory() + "sb-format-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let img = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
    let tiff = img.tiffRepresentation!
    let rel = NoteFormat.savePNG(tiff, noteID: "n1", dir: dir, now: Date(timeIntervalSince1970: 0))
    check("a pasted picture is saved as PNG under attachments, named for the note", rel?.hasPrefix("attachments/n1-") == true
          && rel.map { FileManager.default.fileExists(atPath: dir + "/" + $0) } == true, rel ?? "nil")
    try? FileManager.default.removeItem(atPath: dir)

    // Many shapes, the same promises: the selection stays inside the text, a wrap adds or
    // removes exactly its marks, a prefix never changes the line count, a link keeps the words.
    var seed: UInt64 = 0x5EED
    func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, n))) }
    let alphabet = Array("ab cé中\n-*[]()`_ 12\n")
    var bad: [String] = []
    for _ in 0..<300 {
        let text = String((0..<rnd(40)).map { _ in alphabet[rnd(alphabet.count)] })
        let len = (text as NSString).length
        let loc = rnd(len + 1), r = NSRange(location: loc, length: rnd(len - loc + 1))
        for (name, e, promise) in [
            ("bold", NoteFormat.wrap(text, r, "**"), { (e: NoteFormat.Edit) in abs((e.text as NSString).length - len) == 4 }),
            ("code", NoteFormat.wrap(text, r, "`"), { abs(($0.text as NSString).length - len) == 2 }),
            ("list", NoteFormat.prefixLines(text, r, "- "), { $0.text.filter { $0 == "\n" }.count == text.filter { $0 == "\n" }.count }),
            ("link", NoteFormat.link(text, r, clipboard: "https://a.b"), { $0.text.contains("](https://a.b)") }),
            ("image", NoteFormat.image(text, r, path: "attachments/p.png", name: "p"), { $0.text.contains("![p](attachments/p.png)\n") }),
        ] as [(String, NoteFormat.Edit, (NoteFormat.Edit) -> Bool)] {
            let inside = e.selection.location >= 0 && e.selection.location + e.selection.length <= (e.text as NSString).length
            if !inside || !promise(e) { bad.append("\(name) on \(text.debugDescription) at \(r): \(e)") }
        }
    }
    check("300 random texts and selections keep every edit's promise", bad.isEmpty, bad.prefix(2).joined(separator: " · "))
    return lines
}
