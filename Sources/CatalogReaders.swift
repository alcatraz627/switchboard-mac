// CatalogReaders.swift
// What each list tab reads from ~/.claude. One function per section; each
// returns entries or throws a CatalogError the section shows in words.

import AppKit
import Foundation

private var gcc: String { SwitchboardPaths.gccRoot }

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
