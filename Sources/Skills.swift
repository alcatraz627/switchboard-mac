// Skills.swift
// The Skills tab: every skill under ~/.claude/skills, by name, opening to its
// description and the path to its SKILL.md, which copies on click.

import Foundation

enum SkillsIndex {
    struct Skill {
        let name: String
        let description: String
        let path: String
    }

    static var dir: String { SwitchboardPaths.gccRoot + "/skills" }

    /// Every skill with a readable SKILL.md, by name.
    static func all() -> [Skill] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { folder in
            let path = dir + "/" + folder + "/SKILL.md"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let fields = frontmatter(text)
            return Skill(name: fields["name"] ?? folder, description: fields["description"] ?? "", path: path)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The `key: value` pairs between the opening `---` lines. Handles quoted
    /// values and `>`/`|` blocks, which some descriptions use to wrap.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                var block: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].isEmpty {
                    if lines[i].trimmingCharacters(in: .whitespaces) == "---" { break }
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = block.joined(separator: value.hasPrefix("|") ? "\n" : " ").trimmingCharacters(in: .whitespaces)
            } else if value.count >= 2, let q = value.first, (q == "\"" || q == "'"), value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// The tab's rows: one per skill, opening to its description and path.
    static func groups() -> [SystemGroup] {
        let skills = all()
        guard !skills.isEmpty else { return [] }
        let rows: [SystemRow] = skills.map { s in
            // The first sentence: a period followed by a capital, so "incl." or "e.g." do not cut it short.
            let firstSentence: String = {
                guard let r = s.description.range(of: #"\.\s+(?=[A-Z])"#, options: .regularExpression) else { return s.description }
                return String(s.description[..<r.lowerBound]) + "."
            }()
            var r = SystemRow(label: "/" + s.name, state: .off, note: firstSentence, tip: s.description)
            r.key = "skill-" + s.path
            r.showsBadge = false
            r.noteLines = 0   // one sentence, never cut to "…"
            var desc = SystemRow(label: "Description", state: .off,
                                 note: s.description.isEmpty ? "No description in its frontmatter." : s.description)
            desc.key = r.key! + "-desc"
            desc.showsBadge = false
            desc.noteLines = 0
            var file = SystemRow(label: "SKILL.md", state: .off, note: s.path, tip: "Copy the path")
            file.key = r.key! + "-path"
            file.showsBadge = false
            file.buttons = [RowButton(label: "Copy", kind: .copy(s.path), help: "Copy \(s.path)")]
            r.children = [desc, file]
            return r
        }
        return [SystemGroup(title: "Skills", rows: rows)]
    }
}
