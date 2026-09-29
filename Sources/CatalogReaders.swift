// CatalogReaders.swift
// What each list tab reads from ~/.claude. One function per section; each
// returns entries or throws a CatalogError the section shows in words.

import AppKit
import Foundation

private var gcc: String { SwitchboardPaths.gccRoot }

// ── Rules & Hooks: behavioural rules and every hook script ──────────────────

enum RulesCatalog {
    static func groups() -> [SystemGroup] {
        [Catalog.section("Rules", rules), Catalog.section("Hook scripts", hooks)]
    }

    /// Each rule's brief, whether every session loads it or only when a
    /// matching file is touched (a `paths:` block), and what else triggers it.
    static func rules() throws -> [CatalogEntry] {
        try Catalog.markdownFiles(in: gcc + "/rules").compactMap { path -> CatalogEntry? in
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard name != "README", name != "00-index",
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let f = Catalog.frontmatter(text)
            let brief = f["brief"] ?? ""
            let scoped = f["paths"].map { !$0.isEmpty } ?? false
            var details: [(String, String)] = [("What it says", brief.isEmpty ? "No brief in its frontmatter." : brief),
                                               ("Loads", scoped ? "only when a file matching its paths is touched: \(f["paths"]!)" : "in every session")]
            if let t = f["triggers"], !t.isEmpty { details.append(("Also triggered by", t)) }
            if let r = f["related"], !r.isEmpty { details.append(("Related", r)) }
            let bytes = text.utf8.count
            details.append(("Size", "\(bytes) bytes" + (!scoped && bytes > 2200 ? ", over the 2,200 cap for an always-loaded rule" : "")))
            return CatalogEntry(name: name, summary: Catalog.firstSentence(brief), details: details, path: path,
                                tag: scoped ? "scoped" : "always")
        }
    }

    /// Where a hook script runs from: an event in settings.json, a line in a
    /// hook-orchestrator tasks file (muted when it starts "# DISABLED"), or
    /// another hook that calls it.
    struct Wiring { var events: [String] = []; var muted: [String] = []; var usedBy: [String] = [] }

    static func hooks() throws -> [CatalogEntry] {
        let hookDir = gcc + "/scripts/hooks"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: hookDir) else {
            throw CatalogError("\(abbreviateHome(hookDir)) could not be read")
        }
        var wiring: [String: Wiring] = [:]
        for (event, command) in settingsHooks() {
            for p in scriptPaths(in: command) { wiring[p, default: Wiring()].events.append(event) }
        }
        let orch = gcc + "/scripts/hook-orchestrator"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: orch)) ?? [] where file.hasSuffix(".tasks") {
            let event = String(file.dropLast(".tasks".count))
            for line in ((try? String(contentsOfFile: orch + "/" + file, encoding: .utf8)) ?? "").components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("# DISABLED ") {
                    for p in scriptPaths(in: String(t.dropFirst("# DISABLED ".count))) { wiring[p, default: Wiring()].muted.append(event) }
                } else if !t.isEmpty, !t.hasPrefix("#") {
                    for p in scriptPaths(in: t) { wiring[p, default: Wiring()].events.append(event + " (orchestrator)") }
                }
            }
        }
        let files = names.filter { ($0.hasSuffix(".sh") || $0.hasSuffix(".py")) && !$0.contains(".test.") && !$0.hasPrefix("test-") }
            .map { hookDir + "/" + $0 }
        // A script another script runs is in use even with no event of its
        // own. Comment lines and test folders do not count as a call.
        let bodies = liveScriptBodies(gcc + "/scripts")
        for path in files {
            let base = (path as NSString).lastPathComponent
            let users = bodies.filter { $0.0 != path && $0.1.contains(base) }.map { ($0.0 as NSString).lastPathComponent }
            if !users.isEmpty { wiring[path, default: Wiring()].usedBy = users.sorted() }
        }
        let all = Set(files).union(wiring.keys)
        let ranked: [(Bool, CatalogEntry)] = all.map { path -> (Bool, CatalogEntry) in
            let w = wiring[path] ?? Wiring()
            let exists = FileManager.default.fileExists(atPath: path)
            let events = Array(Set(w.events)).sorted()
            let tag: String
            if !exists { tag = "missing file" }
            else if !events.isEmpty { tag = events.joined(separator: ", ") }
            else if !w.muted.isEmpty { tag = "muted in " + w.muted.joined(separator: ", ") }
            else if let first = w.usedBy.first { tag = "run by " + first + (w.usedBy.count > 1 ? " +\(w.usedBy.count - 1)" : "") }
            else { tag = "not wired" }
            var details: [(String, String)] = []
            let about = exists ? Catalog.scriptSummary(path) : ""
            details.append(("What it says it does", exists ? (about.isEmpty ? "No header comment." : about)
                                                           : "The file is gone, but a hook still names it."))
            details.append(("Runs on", events.isEmpty ? "no event" : events.joined(separator: ", ")))
            if !w.muted.isEmpty { details.append(("Muted", "commented out with # DISABLED in " + w.muted.joined(separator: ", "))) }
            if !w.usedBy.isEmpty { details.append(("Called by", w.usedBy.joined(separator: ", "))) }
            let broken = !exists || tag == "not wired"
            let name: String = path.hasPrefix(hookDir + "/") ? (path as NSString).lastPathComponent
                : abbreviateHome(path).replacingOccurrences(of: "~/.claude/scripts/", with: "")
            let entry = CatalogEntry(name: name, summary: about, details: details, path: exists ? path : nil, tag: tag)
            return (broken, entry)
        }
        // Problems first, then by name.
        return ranked.sorted { a, b in a.0 != b.0 ? a.0 : a.1.name.lowercased() < b.1.name.lowercased() }.map { $0.1 }
    }

    /// Each script under a folder with its comment lines removed, skipping
    /// tests, fixtures and replay corpora.
    static func liveScriptBodies(_ root: String) -> [(String, String)] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [(String, String)] = []
        while let rel = walker.nextObject() as? String {
            let leaf = (rel as NSString).lastPathComponent
            if ["tests", "test", "fixtures", "replay", "node_modules", "__pycache__"].contains(leaf) || leaf.hasPrefix(".") {
                walker.skipDescendants(); continue
            }
            guard rel.hasSuffix(".sh") || rel.hasSuffix(".py"), !rel.contains(".test."), !leaf.hasPrefix("test-"),
                  (walker.fileAttributes?[.type] as? FileAttributeType) != .typeSymbolicLink,
                  let text = try? String(contentsOfFile: root + "/" + rel, encoding: .utf8) else { continue }
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            out.append((root + "/" + rel, code))
        }
        return out
    }

    /// Every (event, command) pair in settings.json and settings.local.json.
    static func settingsHooks() -> [(String, String)] {
        var out: [(String, String)] = []
        for file in ["settings.json", "settings.local.json"] {
            guard let d = FileManager.default.contents(atPath: gcc + "/" + file),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let hooks = o["hooks"] as? [String: Any] else { continue }
            for (event, v) in hooks {
                for block in v as? [[String: Any]] ?? [] {
                    for h in block["hooks"] as? [[String: Any]] ?? [] {
                        if let c = h["command"] as? String { out.append((event, c)) }
                    }
                }
            }
        }
        return out
    }

    /// Script files a command line runs, with ~ and $HOME expanded.
    static func scriptPaths(in command: String) -> [String] {
        command.split(separator: " ").map(String.init).compactMap { tok in
            guard tok.hasSuffix(".sh") || tok.hasSuffix(".py"), tok.contains("/") else { return nil }
            var p = tok.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if p.hasPrefix("~/") { p = NSHomeDirectory() + p.dropFirst(1) }
            p = p.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
            return (p as NSString).standardizingPath
        }
    }
}

// ── Library: skills, parked skills, knowledge, personas, scripts ────────────

enum LibraryCatalog {
    static func groups() -> [SystemGroup] {
        [Catalog.section("Skills", skills), Catalog.section("Parked skills", parked),
         Catalog.section("Knowledge", knowledge), Catalog.section("Personas", personas),
         Catalog.section("Scripts", scripts)]
    }

    static func skills() throws -> [CatalogEntry] {
        let dir = gcc + "/skills"
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw CatalogError("\(abbreviateHome(dir)) could not be read")
        }
        return folders.compactMap { folder -> CatalogEntry? in
            let path = dir + "/" + folder + "/SKILL.md"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let f = Catalog.frontmatter(text)
            let desc = f["description"] ?? ""
            return CatalogEntry(name: "/" + (f["name"] ?? folder), summary: Catalog.firstSentence(desc),
                                details: [("Description", desc.isEmpty ? "No description in its frontmatter." : desc)],
                                path: path)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Parked skills are kept but not loaded; the index says when each is worth
    /// bringing back, and the row copies the command that installs it.
    static func parked() throws -> [CatalogEntry] {
        let dir = gcc + "/skills-parked"
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw CatalogError("\(abbreviateHome(dir)) could not be read")
        }
        let index = parkedIndex(dir + "/INDEX.md")
        return folders.compactMap { folder -> CatalogEntry? in
            let path = dir + "/" + folder + "/SKILL.md"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let f = Catalog.frontmatter(text)
            let name = f["name"] ?? folder
            let desc = f["description"] ?? ""
            var details: [(String, String)] = []
            if let when = index[folder]?.when, !when.isEmpty { details.append(("Bring it back when", when)) }
            if let tags = index[folder]?.tags, !tags.isEmpty { details.append(("Tags", tags)) }
            details.append(("Description", desc.isEmpty ? "No description in its frontmatter." : desc))
            let cmd = "bash ~/.claude/scripts/parked/parked.sh copy \(folder) --to ."
            details.append(("Install into a project", cmd))
            return CatalogEntry(name: "/" + name, summary: Catalog.firstSentence(desc), details: details, path: path,
                                tag: "parked",
                                actions: [RowButton(label: "Copy", kind: .copy(cmd),
                                                    help: "Copy the command that installs it into the current project")])
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The INDEX.md table: skill → (tags, when to bring it back).
    private static func parkedIndex(_ path: String) -> [String: (tags: String, when: String)] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: (String, String)] = [:]
        for line in text.components(separatedBy: "\n") where line.hasPrefix("| `") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            out[cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))] = (cells[3], cells[4])
        }
        return out
    }

    /// Feature and convention docs and global memories: what each is, what
    /// loads it, and whether it is past its own review date.
    static func knowledge() throws -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        for (folder, kind) in [("features", "feature"), ("conventions", "convention"), ("memory/global", "memory")] {
            for path in try Catalog.markdownFiles(in: gcc + "/" + folder) {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                guard name != "README", name != "MEMORY",
                      let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let f = Catalog.frontmatter(text)
                let about = f["brief"] ?? f["description"] ?? ""
                var details: [(String, String)] = [("What it is", about.isEmpty ? "No brief in its frontmatter." : about)]
                if let t = f["triggers"], !t.isEmpty { details.append(("Loads on", t)) }
                if let r = f["related"], !r.isEmpty { details.append(("Related", r)) }
                var tag = kind
                if let u = f["updated"] {
                    let limit = f["stale_after_days"].flatMap(Int.init)
                    let age = updatedAge(u)
                    details.append(("Updated", u + (limit.map { " · review every \($0) days" } ?? "")))
                    if let a = age, let l = limit, a > l { tag += " · past review by \(a - l) days" }
                }
                out.append(CatalogEntry(name: f["name"].map { $0.count < 60 ? $0 : name } ?? name,
                                        summary: Catalog.firstSentence(about), details: details, path: path, tag: tag))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func updatedAge(_ ymd: String) -> Int? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(ymd.prefix(10))) else { return nil }
        return Int(Date().timeIntervalSince(d) / 86400)
    }

    static func personas() throws -> [CatalogEntry] {
        let dir = gcc + "/personas"
        var paths = try Catalog.markdownFiles(in: dir)
        paths += (try? Catalog.markdownFiles(in: dir + "/_proposed")) ?? []
        return paths.compactMap { path -> CatalogEntry? in
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard file != "README", file != "BUILD_LOG",
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let f = Catalog.frontmatter(text)
            let role = f["role"] ?? f["description"] ?? ""
            var details: [(String, String)] = [("Role", role.isEmpty ? "No role in its frontmatter." : role)]
            if let d = f["domain"] { details.append(("Domain", d)) }
            if let t = f["type"] { details.append(("Kind", t)) }
            details.append(("Adopt it", "/persona \(f["name"] ?? file)"))
            return CatalogEntry(name: f["name"] ?? file, summary: Catalog.firstSentence(role), details: details, path: path,
                                tag: path.contains("/_proposed/") ? "proposed" : nil)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Every script except hooks (Rules & Hooks lists those) and tests, named
    /// by its path under scripts/, summarised by its own header comment.
    static func scripts() throws -> [CatalogEntry] {
        let root = gcc + "/scripts"
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            throw CatalogError("\(abbreviateHome(root)) could not be read")
        }
        var out: [CatalogEntry] = []
        while let rel = walker.nextObject() as? String {
            let parts = rel.split(separator: "/")
            if parts.contains(where: { ["hooks", "tests", "test", "fixtures", "node_modules", "__pycache__"].contains(String($0)) || $0.hasPrefix(".") }) {
                if (walker.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { walker.skipDescendants() }
                continue
            }
            guard rel.hasSuffix(".sh") || rel.hasSuffix(".py"), !rel.contains(".test."), !rel.hasSuffix("_test.py") else { continue }
            // The top level keeps old-path symlinks to scripts that moved; list each once, where it lives.
            if (walker.fileAttributes?[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            let path = root + "/" + rel
            let about = Catalog.scriptSummary(path)
            out.append(CatalogEntry(name: rel, summary: about,
                                    details: [("What it says it does", about.isEmpty ? "No header comment." : about)],
                                    path: path))
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
