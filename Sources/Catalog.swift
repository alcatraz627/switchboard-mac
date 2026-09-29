// Catalog.swift
// The shared machinery behind every list tab (Library, Rules & Hooks, Ledger,
// Plugins & MCP): one entry shape, one row that opens to its details, a path
// that copies on click, and a section that says so when its source could not
// be read. The readers that fill it live in CatalogReaders.swift.

import AppKit
import Foundation

/// One thing a list tab shows: a skill, a rule, a script, a mistake.
struct CatalogEntry {
    var name: String
    /// One sentence under the name; the full text goes in `details`.
    var summary: String
    /// Label and value pairs that open below the row, long text allowed.
    var details: [(String, String)] = []
    /// The file behind it; its row copies the path.
    var path: String? = nil
    /// A short word before the summary, such as "scoped" or "unwired".
    var tag: String? = nil
    /// A number on the right, such as how often a mistake recurred.
    var count: (Int, NSColor)? = nil
    /// Buttons on the row itself, such as copying the command that restores it.
    var actions: [RowButton] = []
    /// Turned off: drawn struck through and dimmed.
    var off = false
}

/// A reader could not read its source; the message is shown to the owner.
struct CatalogError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum Catalog {
    /// One section: its entries as rows, or a failed status when the reader
    /// threw, so a broken source never reads as an empty one.
    static func section(_ title: String, _ read: () throws -> [CatalogEntry]) -> SystemGroup {
        do {
            let entries = try read()
            let rows = entries.map { row($0, key: title) }
            return SystemGroup(title: title, rows: rows,
                               status: rows.isEmpty ? .unavailable("Nothing here yet.") : nil)
        } catch let e as CatalogError {
            return SystemGroup(title: title, rows: [], status: .failed(e.message))
        } catch {
            return SystemGroup(title: title, rows: [], status: .failed(error.localizedDescription))
        }
    }

    /// Longest summary under a name; the whole text is one click away in the details.
    static let summaryChars = 180

    /// A tab's sections, skipping those hidden in Settings without reading them.
    static func sections(_ tab: String, _ readers: [(String, () throws -> [CatalogEntry])]) -> [SystemGroup] {
        let hidden = Visibility.hiddenTitles(tab)
        return readers.filter { !hidden.contains($0.0) }.map { section($0.0, $0.1) }
    }

    static func row(_ e: CatalogEntry, key: String) -> SystemRow {
        var summary = e.summary.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\n", with: " ")
        if summary.count > summaryChars {
            let cut = summary.prefix(summaryChars)
            summary = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
        }
        let note = [e.tag, summary.isEmpty ? nil : summary].compactMap { $0 }.joined(separator: " · ")
        let state: SystemRow.State = e.count.map { .count($0.0, $0.1) } ?? .off
        var r = SystemRow(label: e.name, state: state, note: note, tip: e.summary)
        // Name and path both: one config file can hold several entries.
        r.key = key + "::" + (e.path ?? "") + "::" + e.name + "::" + (e.tag ?? "")
        r.showsBadge = e.count != nil
        r.noteLines = 0
        r.buttons = e.actions
        r.struck = e.off
        var kids: [SystemRow] = e.details.enumerated().map { i, d in
            var c = SystemRow(label: d.0, state: .off, note: d.1, tip: d.1)
            c.key = r.key! + "-d\(i)"
            c.showsBadge = false
            c.noteLines = 0
            return c
        }
        if let p = e.path {
            var file = SystemRow(label: (p as NSString).lastPathComponent, state: .off, note: abbreviateHome(p), tip: "Copy the path")
            file.key = r.key! + "-path"
            file.showsBadge = false
            file.buttons = [RowButton(label: "Copy", kind: .copy(p), help: "Copy \(p)")]
            kids.append(file)
        }
        r.children = kids
        return r
    }

    /// Rows whose name, note or opened details contain every word of the
    /// query; sections with no match drop out while a query is typed.
    static func filter(_ groups: [SystemGroup], _ query: String) -> [SystemGroup] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { g in
            let rows = g.rows.filter { r in
                let hay = ([r.label, r.note] + r.children.map { $0.note }).joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            return rows.isEmpty ? nil : SystemGroup(title: g.title, rows: rows, status: nil)
        }
    }

    /// Re-reads one list tab after a row changed what it lists (a plugin
    /// turned off). The panel sets it; headless runs leave it a no-op.
    static var reload: (String) -> Void = { _ in }

    /// How many rows a section shows before "Show all".
    static let previewRows = 6

    /// A section cut to its first few rows plus a row that shows the rest,
    /// or back to "Show fewer" once opened. Searching bypasses this.
    static func preview(_ g: SystemGroup, tab: String, store: PolicyStore) -> SystemGroup {
        guard g.rows.count > previewRows + 1 else { return g }
        let key = tab + "::" + g.title
        let open = store.shownInFull.contains(key)
        var toggle = SystemRow(label: open ? "Show fewer" : "Show all \(g.rows.count)", state: .count(g.rows.count, .systemGray),
                               note: open ? "" : "\(g.rows.count - previewRows) more; or search above",
                               action: { if open { store.shownInFull.remove(key) } else { store.shownInFull.insert(key) } })
        toggle.key = key + "::toggle"
        toggle.buttonLabel = open ? "Fewer" : "All"
        toggle.showsBadge = false
        return SystemGroup(title: g.title, rows: (open ? g.rows : Array(g.rows.prefix(previewRows))) + [toggle], status: g.status)
    }

    // ── Reading the files ───────────────────────────────────────────────────

    /// The `key: value` pairs between the opening `---` lines. Handles quoted
    /// values and `>`/`|` blocks, which some descriptions use to wrap. A list
    /// value (`key:` followed by `- item` lines) comes back comma-joined.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                var items: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("-") {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") { items.append(unquote(String(t.dropFirst(2)))) }
                    i += 1
                }
                value = items.joined(separator: ", ")
            } else if value == ">" || value == "|" || value == ">-" || value == "|-" {
                var block: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].isEmpty {
                    if lines[i].trimmingCharacters(in: .whitespaces) == "---" { break }
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = block.joined(separator: value.hasPrefix("|") ? "\n" : " ").trimmingCharacters(in: .whitespaces)
            } else {
                value = unquote(value)
            }
            out[key] = value
        }
        return out
    }

    private static func unquote(_ v: String) -> String {
        guard v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q else { return v }
        return String(v.dropFirst().dropLast())
    }

    /// The first sentence: a period followed by a capital, so "incl." or
    /// "e.g." do not cut it short.
    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: #"\.\s+(?=[A-Z])"#, options: .regularExpression) else { return t }
        return String(t[..<r.lowerBound]) + "."
    }

    /// What a script says it is: the first comment line after the shebang,
    /// or the first line of a Python docstring, without a leading
    /// "name.sh — " that only repeats the file name.
    static func scriptSummary(_ path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        // The header's first paragraph: comment or docstring lines up to a
        // blank one, skipping banners made only of rule characters.
        var para: [String] = []
        var inDoc = false
        for raw in head.components(separatedBy: "\n").prefix(30) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!") || line.hasPrefix("# -*-") { continue }
            if line.hasPrefix("\"\"\"") { inDoc = true; line = String(line.dropFirst(3)) }
            else if line.hasPrefix("#") { line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            else if !inDoc { if para.isEmpty { continue } else { break } }
            let ends = line.contains("\"\"\"")
            line = line.replacingOccurrences(of: "\"\"\"", with: "").trimmingCharacters(in: .whitespaces)
            let decoration = !line.isEmpty && line.allSatisfy { "=-─━#*~_".contains($0) }
            if line.isEmpty || decoration { if para.isEmpty { if ends { inDoc = false }; continue } else { break } }
            para.append(line)
            if ends { break }
        }
        var text = para.joined(separator: " ")
        for sep in [" — ", " - ", ": "] where text.hasPrefix(name + sep) || text.hasPrefix(stem + sep) {
            text = String(text[text.range(of: sep)!.upperBound...])
            break
        }
        let sentence = firstSentence(text)
        return sentence.count > 220 ? String(sentence.prefix(217)) + "…" : sentence
    }

    /// The .md files directly in a folder, or a CatalogError saying the
    /// folder is missing.
    static func markdownFiles(in dir: String) throws -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw CatalogError("\(abbreviateHome(dir)) could not be read")
        }
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted().map { dir + "/" + $0 }
    }

    /// Days since a file last changed.
    static func ageDays(_ path: String) -> Int? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        return Int(Date().timeIntervalSince(d) / 86400)
    }
}

// ── Headless probe ──────────────────────────────────────────────────────────

/// Checks the list machinery on planted files in a scratch folder: parsing,
/// a failing source, the first-rows preview and its toggle, and search.
func probeCatalog() -> String {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "sb-catalog-probe-\(getpid())"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }

    let f = Catalog.frontmatter("---\nbrief: \"A quoted brief\"\ntriggers:\n  - topic:a\n  - \"phrase:b\"\ndesc: >\n  wrapped\n  text\n---\nbody")
    check("a quoted value loses its quotes", f["brief"] == "A quoted brief", f["brief"] ?? "nil")
    check("a list value comes back comma-joined", f["triggers"] == "topic:a, phrase:b", f["triggers"] ?? "nil")
    check("a folded block joins its lines", f["desc"] == "wrapped text", f["desc"] ?? "nil")
    check("the first sentence survives an abbreviation", Catalog.firstSentence("Uses e.g. files. Then more.") == "Uses e.g. files.")

    let wrapped = dir + "/wrapped.sh"
    fm.createFile(atPath: wrapped, contents: Data("#!/bin/bash\n# wrapped.sh — inject the thing into each\n# session at start. More detail here.\n#\n# Usage: x\n".utf8))
    check("a header that wraps is one sentence, without its own file name",
          Catalog.scriptSummary(wrapped) == "inject the thing into each session at start.", Catalog.scriptSummary(wrapped))
    let banner = dir + "/banner.sh"
    fm.createFile(atPath: banner, contents: Data("#!/bin/bash\n# ==========\n# ARCHIVED, do not run.\n# ==========\n".utf8))
    check("a banner line is skipped", Catalog.scriptSummary(banner) == "ARCHIVED, do not run.", Catalog.scriptSummary(banner))

    let failed = Catalog.section("Broken") { throw CatalogError("the folder is gone") }
    check("a source that fails shows why, not an empty section", failed.status == .failed("the folder is gone") && failed.rows.isEmpty)
    let empty = Catalog.section("Empty") { [] }
    check("a source with nothing says so", empty.status == .unavailable("Nothing here yet."))

    let many = Catalog.section("Many") { (1...20).map { CatalogEntry(name: "item \($0)", summary: "thing \($0)") } }
    let store = PolicyStore()
    let cut = Catalog.preview(many, tab: "t", store: store)
    check("a long section shows its first rows and a Show all row",
          cut.rows.count == Catalog.previewRows + 1 && cut.rows.last?.label == "Show all 20", "\(cut.rows.count) \(cut.rows.last?.label ?? "")")
    cut.rows.last?.action?()
    let open = Catalog.preview(many, tab: "t", store: store)
    check("Show all opens every row, with Show fewer at the end",
          open.rows.count == 21 && open.rows.last?.label == "Show fewer", "\(open.rows.count)")
    let found = Catalog.filter([many], "item 1")
    check("search keeps every match and drops the rest", found.first?.rows.count == 11, "\(found.first?.rows.count ?? 0)")
    check("a section with no match drops out while searching", Catalog.filter([many, empty], "nothing-matches").isEmpty)

    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

/// "~/.claude/skills" for a path under the home folder.
func abbreviateHome(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}
