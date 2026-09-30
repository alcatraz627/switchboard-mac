// CatalogReaders.swift
// What each list tab reads from ~/.claude. One function per section; each
// returns entries or throws a CatalogError the section shows in words.

import AppKit
import Foundation

private var gcc: String { SwitchboardPaths.gccRoot }

/// A read that two sections share, done once and only if one of them asks.
private func lazyRead(_ read: @escaping () throws -> [CatalogEntry]) -> () throws -> [CatalogEntry] {
    var memo: Result<[CatalogEntry], Error>?
    return {
        if memo == nil { memo = Result { try read() } }
        return try memo!.get()
    }
}

// ── Rules & Hooks: behavioural rules and every hook script ──────────────────

enum RulesCatalog {
    static func groups() -> [SystemGroup] {
        Catalog.sections("rules", [("Rules", rules), ("Hook scripts", hooks)])
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
        let callers = scriptCallers(liveScriptBodies(gcc + "/scripts"))
        for path in files {
            let users = (callers[(path as NSString).lastPathComponent] ?? []).filter { $0 != path }
                .map { ($0 as NSString).lastPathComponent }
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

    /// Which scripts name each script file, keyed by file name. One pass over
    /// the bodies, splitting on anything that cannot be part of a file name.
    static func scriptCallers(_ bodies: [(String, String)]) -> [String: [String]] {
        let nameChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        var out: [String: [String]] = [:]
        for (path, code) in bodies {
            let names = Set(code.components(separatedBy: nameChars.inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                .filter { $0.hasSuffix(".sh") || $0.hasSuffix(".py") })
            for n in names { out[n, default: []].append(path) }
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

// ── Plugins & MCP: what extends Claude Code, everywhere or in one project ───

enum PluginsCatalog {
    /// Section titles starting "Project" hold things that apply in one repo;
    /// the tab's filter shows or hides them by that prefix.
    static func groups() -> [SystemGroup] {
        let installed = lazyRead(plugins)
        return Catalog.sections("plugins", [
            ("Plugins", { try installed().filter { $0.tag?.contains("project") == false } }),
            ("MCP servers", globalMCP),
            ("Project plugins", { try installed().filter { $0.tag?.contains("project") == true } }),
            ("Project MCP servers", projectMCP)])
    }

    static func plugins() throws -> [CatalogEntry] {
        let path = gcc + "/plugins/installed_plugins.json"
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let all = o["plugins"] as? [String: Any] else {
            throw CatalogError("\(abbreviateHome(path)) could not be read")
        }
        let enabled = (settingsJSON()?["enabledPlugins"] as? [String: Bool]) ?? [:]
        return all.compactMap { id, v -> CatalogEntry? in
            guard let rec = (v as? [[String: Any]])?.first else { return nil }
            let parts = id.split(separator: "@").map(String.init)
            let name = parts.first ?? id, market = parts.count > 1 ? parts[1] : "?"
            let dir = (rec["installPath"] as? String) ?? ""
            let manifest = FileManager.default.contents(atPath: dir + "/.claude-plugin/plugin.json")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let about = (manifest?["description"] as? String) ?? ""
            let on = enabled[id] ?? true
            let project = rec["projectPath"] as? String
            var details: [(String, String)] = [("What it is", about.isEmpty ? "No description in its plugin.json." : about)]
            let adds = ["skills", "commands", "agents", "hooks"].compactMap { sub -> String? in
                let n = ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/" + sub)) ?? []).filter { !$0.hasPrefix(".") }.count
                return n > 0 ? "\(n) \(sub)" : nil
            } + (FileManager.default.fileExists(atPath: dir + "/.mcp.json") ? ["an MCP server"] : [])
            details.append(("Adds", adds.isEmpty ? "nothing it lists in folders" : adds.joined(separator: ", ")))
            details.append(("Source", "\(market) · version \((rec["version"] as? String) ?? "?")"))
            if let p = project { details.append(("Project", abbreviateHome(p))) }
            details.append(("State", on ? "enabled in settings.json" : "installed but turned off in settings.json"))
            let flip = RowButton(label: on ? "Disable" : "Enable", kind: .run({
                setPlugin(id, on: !on)
            }), help: on ? "Turn \(name) off for new sessions" : "Turn \(name) on for new sessions",
               doing: on ? "turn \(name) off" : "turn \(name) on")
            return CatalogEntry(name: name, summary: Catalog.firstSentence(about), details: details,
                                path: dir.isEmpty ? nil : dir + "/.claude-plugin/plugin.json",
                                tag: (on ? "on" : "off") + " · \(market)" + (project.map { " · project \(($0 as NSString).lastPathComponent)" } ?? ""),
                                actions: [flip], off: !on)
        }
        .sorted { ($0.tag?.hasPrefix("on") == true ? 0 : 1, $0.name) < ($1.tag?.hasPrefix("on") == true ? 0 : 1, $1.name) }
    }

    static func globalMCP() throws -> [CatalogEntry] {
        let path = NSHomeDirectory() + "/.claude.json"
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw CatalogError("~/.claude.json could not be read")
        }
        // Claude Code documents no everywhere-off switch for these; only a per-project
        // list inside ~/.claude.json, which also holds the login, so the panel leaves it be.
        var out = servers(o["mcpServers"] as? [String: Any] ?? [:], file: path, project: nil).map { e -> CatalogEntry in
            var e = e
            e.details.append(("Turning it off", "Claude Code has no everywhere-off switch for these. /mcp in a session turns one off for that project; `claude mcp remove \(e.name)` removes it."))
            return e
        }
        for (dir, p) in o["projects"] as? [String: Any] ?? [:] {
            out += servers((p as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:], file: path, project: dir)
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Every .mcp.json in a repo under ~/Code, four folders deep at most.
    static func projectMCP() throws -> [CatalogEntry] {
        let root = NSHomeDirectory() + "/Code"
        guard let walker = FileManager.default.enumerator(atPath: root) else { throw CatalogError("~/Code could not be read") }
        var out: [CatalogEntry] = []
        while let rel = walker.nextObject() as? String {
            let leaf = (rel as NSString).lastPathComponent
            if walker.level > 4 || ["node_modules", ".git", "build", "dist", ".venv"].contains(leaf) { walker.skipDescendants(); continue }
            guard leaf == ".mcp.json",
                  let d = FileManager.default.contents(atPath: root + "/" + rel),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let dir = root + "/" + (rel as NSString).deletingLastPathComponent
            let approval = mcpjsonApproval(dir)
            out += servers(o["mcpServers"] as? [String: Any] ?? [:], file: root + "/" + rel, project: dir).map { e in
                var e = e
                let state = approval(e.name)
                e.tag = "\(state.word) · " + (e.tag ?? "")
                e.off = state == .off
                e.actions = [RowButton(label: state == .off ? "Enable" : "Disable", kind: .run({
                    setMcpjson(e.name, in: dir, on: state == .off)
                }), help: state == .off ? "Allow \(e.name) in \(projectName(dir))" : "Turn \(e.name) off in \(projectName(dir))",
                   doing: state == .off ? "turn \(e.name) on" : "turn \(e.name) off")]
                e.details.append(("State", state.detail))
                return e
            }
        }
        return out.sorted { ($0.name, $0.tag ?? "") < ($1.name, $1.tag ?? "") }
    }

    /// One entry per server. Keys and tokens never reach the panel: env shows
    /// names only, a URL shows its host, and a secret-looking argument is hidden.
    static func servers(_ map: [String: Any], file: String, project: String?) -> [CatalogEntry] {
        map.compactMap { name, v -> CatalogEntry? in
            guard let s = v as? [String: Any] else { return nil }
            let type = (s["type"] as? String) ?? (s["url"] != nil ? "http" : "stdio")
            var how: String
            if let url = s["url"] as? String {
                how = "\(type) to \(URL(string: url)?.host ?? "a URL")"
            } else {
                let cmd = ((s["command"] as? String) ?? "?" as NSString as String)
                let args = (s["args"] as? [String] ?? []).map(redact)
                how = ([(cmd as NSString).lastPathComponent] + args).joined(separator: " ")
            }
            var details: [(String, String)] = [("Runs", how)]
            if let env = s["env"] as? [String: Any], !env.isEmpty {
                details.append(("Environment", env.keys.sorted().joined(separator: ", ") + " (values not shown)"))
            }
            if let p = project { details.append(("Project", abbreviateHome(p))) }
            details.append(("Configured in", abbreviateHome(file)))
            return CatalogEntry(name: name, summary: how, details: details, path: file,
                                tag: project.map { "project " + projectName($0) } ?? "everywhere")
        }
    }

    /// "walmart-mvp/frontend" for a repo's subfolder, the repo name otherwise.
    static func projectName(_ dir: String) -> String {
        let parts = dir.split(separator: "/").map(String.init)
        guard let last = parts.last else { return dir }
        return ["frontend", "backend", "web", "app"].contains(last) && parts.count > 1 ? parts[parts.count - 2] + "/" + last : last
    }

    /// Hides an argument that could be a credential: a key=value pair whose key
    /// names a secret, or a long unbroken token.
    static func redact(_ a: String) -> String {
        // user:password@ inside a connection URL
        if a.range(of: #"://[^/@\s:]+:[^/@\s]+@"#, options: .regularExpression) != nil {
            return a.replacingOccurrences(of: #"://[^/@\s:]+:[^/@\s]+@"#, with: "://•••@", options: .regularExpression)
        }
        let lower = a.lowercased()
        let secretish = ["key", "token", "secret", "password", "auth"].contains(where: lower.contains)
        if secretish, a.contains("=") {
            return String(a.split(separator: "=").first ?? "") + "=•••"
        }
        // A header argument: "Authorization: Bearer …", "X-Api-Key: …".
        if secretish, let colon = a.firstIndex(of: ":"), !a.contains("://") {
            return String(a[...colon]) + " •••"
        }
        // Known token shapes, whatever their length or position.
        let shapes = #"(Bearer\s+\S+|xox[abprs]-[A-Za-z0-9-]+|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,})"#
        if a.range(of: shapes, options: .regularExpression) != nil {
            return a.replacingOccurrences(of: shapes, with: "•••", options: .regularExpression)
        }
        let token = a.range(of: #"^[A-Za-z0-9_\-\.]{28,}$"#, options: .regularExpression) != nil
        return token && !a.contains("/") ? "•••" : a
    }

    /// Whether Claude Code loads a project's .mcp.json server: listed as
    /// enabled (or all enabled), listed as disabled, or not yet approved, in
    /// which case it asks on the first session there.
    enum McpjsonState {
        case on, off, asks
        var word: String { self == .on ? "on" : self == .off ? "off" : "asks first" }
        var detail: String {
            switch self {
            case .on: return "allowed in this project's settings"
            case .off: return "turned off in this project's .claude/settings.local.json"
            case .asks: return "not approved yet; Claude Code asks the first time a session starts here"
            }
        }
    }

    /// Reads the approval lists from the user's and the project's settings;
    /// a disable anywhere wins over an enable.
    static func mcpjsonApproval(_ project: String) -> (String) -> McpjsonState {
        let files = [gcc + "/settings.json", project + "/.claude/settings.json", project + "/.claude/settings.local.json"]
        let objs = files.compactMap { FileManager.default.contents(atPath: $0) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let enabled = Set(objs.flatMap { $0["enabledMcpjsonServers"] as? [String] ?? [] })
        let disabled = Set(objs.flatMap { $0["disabledMcpjsonServers"] as? [String] ?? [] })
        let all = objs.contains { $0["enableAllProjectMcpServers"] as? Bool == true }
        return { name in disabled.contains(name) ? .off : (all || enabled.contains(name)) ? .on : .asks }
    }

    /// Turn a project's .mcp.json server on or off in that project's
    /// .claude/settings.local.json, the per-user file Claude Code keeps out of
    /// commits. Creates the file with just these keys if it is not there.
    static func setMcpjson(_ name: String, in project: String, on: Bool) -> String? {
        let dir = project + "/.claude", path = dir + "/settings.local.json"
        var obj: [String: Any] = [:]
        if let d = FileManager.default.contents(atPath: path) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return "\(abbreviateHome(path)) is not valid JSON, so it was left alone"
            }
            obj = o
        }
        var enabled = obj["enabledMcpjsonServers"] as? [String] ?? []
        var disabled = obj["disabledMcpjsonServers"] as? [String] ?? []
        enabled.removeAll { $0 == name }
        disabled.removeAll { $0 == name }
        if on { enabled.append(name) } else { disabled.append(name) }
        obj["enabledMcpjsonServers"] = enabled
        obj["disabledMcpjsonServers"] = disabled
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return "\(abbreviateHome(path)) could not be written: \(error.localizedDescription)"
        }
        Catalog.reload("plugins")
        let now = mcpjsonApproval(project)(name)
        return now == (on ? .on : .off) ? nil : "it still reads as \(now.word)"
    }

    /// Turn a plugin on or off in settings.json's enabledPlugins, the switch
    /// Claude Code reads when a session starts. Returns what went wrong, or nil.
    static func setPlugin(_ id: String, on: Bool) -> String? {
        var plugins = (settingsJSON()?["enabledPlugins"] as? [String: Any]) ?? [:]
        plugins[id] = on
        guard Settings.write(key: "enabledPlugins", value: plugins) else {
            return "~/.claude/settings.json could not be written"
        }
        // Read it back rather than trust the write.
        let now = (settingsJSON()?["enabledPlugins"] as? [String: Bool])?[id]
        Catalog.reload("plugins")
        return now == on ? nil : "settings.json still has it \(on ? "off" : "on")"
    }

    private static func settingsJSON() -> [String: Any]? {
        FileManager.default.contents(atPath: gcc + "/settings.json")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Checks that secrets in MCP server arguments never reach the panel, and
/// that ordinary arguments pass untouched. Run by --probe-catalog.
func probeRedaction() -> [String] {
    let cases: [(String, String)] = [
        ("postgresql://admin:hunter2@db.local:5432/app", "postgresql://•••@db.local:5432/app"),
        ("--api-key=sk-abc123", "--api-key=•••"),
        ("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "•••"),
        ("postgresql://localhost:5432/postgres", "postgresql://localhost:5432/postgres"),
        ("/Users/me/Code/server.js", "/Users/me/Code/server.js"),
        ("-y", "-y"),
        ("Authorization: Bearer abc123def456", "Authorization: •••"),
        ("X-Api-Key: 9f8e7d6c", "X-Api-Key: •••"),
        ("xoxb-1234-5678-abcd", "•••"),
        ("--header=AKIAABCDEFGHIJKLMNOP", "--header=•••"),
        ("AKIAABCDEFGHIJKLMNOP", "•••"),
        ("Bearer eyJhbGciOi", "•••"),
        ("@modelcontextprotocol/server-filesystem", "@modelcontextprotocol/server-filesystem"),
        ("--port", "--port"),
    ]
    return cases.map { raw, want in
        let got = PluginsCatalog.redact(raw)
        return "\(got == want ? "ok  " : "FAIL") redacts \(raw.prefix(24))\(got == want ? "" : " (got: \(got))")"
    }
}

/// Turns a plugin and a project MCP server off and on in a scratch folder
/// (never ~/.claude or a real repo) and reads each write back.
func probeToggles() -> [String] {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "sb-toggle-probe-\(getpid())"
    let project = dir + "/repo"
    try? fm.createDirectory(atPath: project, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let realRoot = SwitchboardPaths.gccRoot
    SwitchboardPaths.gccRoot = dir
    defer { SwitchboardPaths.gccRoot = realRoot }
    fm.createFile(atPath: dir + "/settings.json", contents: Data(#"{"enabledPlugins": {"demo@market": true}, "model": "x"}"#.utf8))

    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    check("turning a plugin off reports success", PluginsCatalog.setPlugin("demo@market", on: false) == nil)
    let s = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: dir + "/settings.json") ?? Data())) as? [String: Any]
    check("settings.json has it off and kept every other key",
          (s?["enabledPlugins"] as? [String: Bool])?["demo@market"] == false && s?["model"] as? String == "x")

    let ask = PluginsCatalog.mcpjsonApproval(project)("srv")
    check("a server nobody approved reads as asks first", ask == .asks, ask.word)
    check("turning a project server off reports success", PluginsCatalog.setMcpjson("srv", in: project, on: false) == nil)
    check("it now reads as off", PluginsCatalog.mcpjsonApproval(project)("srv") == .off)
    check("turning it back on reports success", PluginsCatalog.setMcpjson("srv", in: project, on: true) == nil)
    check("it now reads as on", PluginsCatalog.mcpjsonApproval(project)("srv") == .on)
    let local = project + "/.claude/settings.local.json"
    fm.createFile(atPath: local, contents: Data("{broken".utf8))
    let refused = PluginsCatalog.setMcpjson("srv", in: project, on: false)
    check("a broken settings.local.json is refused and left as it was",
          refused?.contains("not valid JSON") == true && String(decoding: fm.contents(atPath: local) ?? Data(), as: UTF8.self) == "{broken",
          refused ?? "nil")
    return lines
}

// ── Queue: what gcc has lined up to happen later ────────────────────────────

enum QueueCatalog {
    static func groups() -> [SystemGroup] {
        Catalog.sections("queue", [("Scheduled", scheduled), ("Cron duties", cronDuties),
                                   ("Deploy queue", deployQueue),
                                   ("Open proposals", { try LedgerCatalog.proposals().filter { $0.tag?.hasPrefix("open") == true } })])
    }

    /// gcc-schedule's registry: one-shots and adopted launchd jobs.
    static func scheduled() throws -> [CatalogEntry] {
        let path = gcc + "/scheduled/registry.json"
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw CatalogError("\(abbreviateHome(path)) could not be read")
        }
        return o.compactMap { name, v -> CatalogEntry? in
            guard let r = v as? [String: Any] else { return nil }
            let when = (r["fire_at"] as? String) ?? "?"
            let about = (r["description"] as? String) ?? ""
            var details: [(String, String)] = [("When", when == "custom-schedule" ? "its own launchd schedule" : when)]
            if !about.isEmpty { details.append(("About", about)) }
            if let c = r["command"] as? String { details.append(("Runs", c)) }
            if let l = r["label"] as? String { details.append(("launchd label", l)) }
            let cmd = "bash ~/.claude/scripts/schedule/schedule.sh show \(name)"
            return CatalogEntry(name: name, summary: about, details: details, path: r["plist"] as? String,
                                tag: when == "custom-schedule" ? "recurring" : "at " + when,
                                actions: [RowButton(label: "Copy", kind: .copy(cmd), help: "Copy: \(cmd)")])
        }
        .sorted { $0.name < $1.name }
    }

    /// Cron duties armed by sessions. One whose session has ended cannot fire,
    /// so it is flagged and sorted first.
    static func cronDuties() throws -> [CatalogEntry] {
        let dir = gcc + "/cron-duties"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw CatalogError("\(abbreviateHome(dir)) could not be read")
        }
        let ranked: [(Bool, CatalogEntry)] = files.filter { $0.hasSuffix(".json") }.compactMap { f in
            guard let d = FileManager.default.contents(atPath: dir + "/" + f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            // No session recorded (a pm2 resident, say) means nothing to outlive.
            let pid = (o["harness_pid"] as? Int).map { Int32($0) }
            // EPERM means the process exists but belongs to another user: alive.
            let alive = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? true
            let sched = (o["schedule"] as? String) ?? "?"
            let head = (o["prompt_head"] as? String) ?? ""
            let details: [(String, String)] = [("Schedule", sched), ("Does", head.isEmpty ? "?" : head),
                                               ("Session", (o["sid"] as? String) ?? "?"),
                                               ("Armed", (o["armed_at"] as? String) ?? "?"),
                                               ("State", pid == nil ? "not tied to a session" : alive ? "its session is running" : "its session has ended, so it will not fire")]
            let e = CatalogEntry(name: (o["slug"] as? String) ?? f, summary: head, details: details, path: dir + "/" + f,
                                 tag: (alive ? "" : "session ended · ") + sched, off: !alive)
            return (!alive, e)
        }
        return ranked.sorted { $0.0 != $1.0 ? $0.0 : $0.1.name < $1.1.name }.map { $0.1 }
    }

    /// Deploys waiting, running, then the last few done.
    static func deployQueue() throws -> [CatalogEntry] {
        let root = gcc + "/deployq"
        guard FileManager.default.fileExists(atPath: root) else { throw CatalogError("~/.claude/deployq is not there") }
        var out: [CatalogEntry] = []
        for (state, limit) in [("running", 50), ("pending", 50), ("done", 5)] {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + state)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted().reversed().prefix(limit)
            for f in files {
                let path = root + "/" + state + "/" + f
                out.append(CatalogEntry(name: f, summary: "", details: [("State", state)], path: path, tag: state))
            }
        }
        return out
    }
}

// ── Ledger: mistakes and proposals ──────────────────────────────────────────

enum LedgerCatalog {
    static func groups() -> [SystemGroup] {
        let props = lazyRead(proposals)
        func part(_ open: Bool) -> () throws -> [CatalogEntry] {
            { try props().filter { ($0.tag?.hasPrefix("open") ?? false) == open } }
        }
        return Catalog.sections("ledger", [("Mistakes", mistakes), ("Open proposals", part(true)), ("Closed proposals", part(false))])
    }

    /// One JSON object per line; a line that does not parse is skipped.
    static func jsonLines(_ path: String) throws -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CatalogError("\(abbreviateHome(path)) could not be read")
        }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Mistakes grouped by pattern: how often, how bad at worst, when last,
    /// and the check that would have caught it. Most frequent first.
    static func mistakes() throws -> [CatalogEntry] {
        let events = try jsonLines(gcc + "/atone/events.jsonl")
        let bySlug = Dictionary(grouping: events) { ($0["slug"] as? String) ?? "unnamed" }
        return bySlug.map { slug, evs -> (Int, String, CatalogEntry) in
            let sorted = evs.sorted { (($0["ts"] as? String) ?? "") > (($1["ts"] as? String) ?? "") }
            let latest = sorted[0]
            let sevs = evs.compactMap { $0["severity"] as? String }
            let worst = sevs.max() ?? "?"
            let last = String(((latest["ts"] as? String) ?? "").prefix(10))
            let precheck = sorted.lazy.compactMap { $0["precheck"] as? String }.first { !$0.isEmpty }
            let whatNot = sorted.lazy.compactMap { $0["what_not_to_do"] as? String }.first { !$0.isEmpty }
            var details: [(String, String)] = []
            if let p = precheck { details.append(("Check before", p)) }
            if let w = whatNot { details.append(("Never again", w)) }
            let counts = ["S3", "S2", "S1"].compactMap { s -> String? in
                let n = sevs.filter { $0 == s }.count
                return n > 0 ? "\(n) \(s)" : nil
            }
            details.append(("Times", "\(evs.count) (\(counts.joined(separator: ", "))), last on \(last)"))
            details.append(("Recent", sorted.prefix(3).map {
                "\(String((($0["ts"] as? String) ?? "").prefix(10))): \(($0["title"] as? String) ?? "")"
            }.joined(separator: "\n")))
            let rca = sorted.lazy.compactMap { $0["rca_id"] as? String }
                .map { gcc + "/atone/rca/\($0).md" }.first { FileManager.default.fileExists(atPath: $0) }
            let tint: NSColor = worst == "S3" ? .systemRed : worst == "S2" ? .systemOrange : .systemGray
            let cmd = "bash ~/.claude/scripts/atone.sh list --slug \(slug)"
            let entry = CatalogEntry(name: slug, summary: (latest["title"] as? String) ?? "", details: details, path: rca,
                                     tag: "\(worst) · last \(last)", count: (evs.count, tint),
                                     actions: [RowButton(label: "Copy", kind: .copy(cmd), help: "Copy: \(cmd)")])
            return (evs.count, last, entry)
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
        .map { $0.2 }
    }

    /// The improvement backlog, newest first, each tagged with its state.
    static func proposals() throws -> [CatalogEntry] {
        try jsonLines(gcc + "/proposals.jsonl").map { p -> (String, CatalogEntry) in
            let id = (p["id"] as? String) ?? "?"
            let status = (p["status"] as? String) ?? "open"
            let ts = String(((p["ts"] as? String) ?? "").prefix(10))
            let body = (p["body"] as? String) ?? ""
            var details: [(String, String)] = [("Proposal", body.isEmpty ? "No body." : body)]
            if let r = p["reason"] as? String, !r.isEmpty { details.append(("Closed because", r)) }
            let meta = [p["category"] as? String, p["effort"] as? String, p["tier"] as? String].compactMap { $0 }
            if !meta.isEmpty { details.append(("Kind", meta.joined(separator: " · "))) }
            if let tags = p["tags"] as? [String], !tags.isEmpty { details.append(("Tags", tags.joined(separator: ", "))) }
            if let links = p["links"] as? [String], !links.isEmpty { details.append(("Links", links.joined(separator: ", "))) }
            if let ups = p["updates"] as? [[String: Any]], !ups.isEmpty {
                details.append(("Updates", ups.suffix(3).map {
                    "\(String((($0["ts"] as? String) ?? "").prefix(10))): \(($0["note"] as? String) ?? "")"
                }.joined(separator: "\n")))
            }
            details.append(("Filed", "\(ts) as \(id)"))
            let cmd = "bash ~/.claude/scripts/propose.sh show \(id)"
            let entry = CatalogEntry(name: (p["title"] as? String) ?? id, summary: Catalog.firstSentence(body),
                                     details: details, tag: "\(status) · \(ts)" + ((p["effort"] as? String).map { " · \($0)" } ?? ""),
                                     actions: [RowButton(label: "Copy", kind: .copy(cmd), help: "Copy: \(cmd)")])
            return ((p["ts"] as? String) ?? "", entry)
        }
        .sorted { $0.0 > $1.0 }
        .map { $0.1 }
    }
}

// ── Library: skills, parked skills, knowledge, personas, scripts ────────────

enum LibraryCatalog {
    static func groups() -> [SystemGroup] {
        Catalog.sections("library", [("Skills", skills), ("Parked skills", parked), ("Knowledge", knowledge),
                                     ("Personas", personas), ("Scripts", scripts)])
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
        var unread: [String] = []
        // A missing folder is left out; the section fails only when none can be read.
        for (folder, kind) in [("features", "feature"), ("conventions", "convention"), ("memory/global", "memory")] {
            guard let files = try? Catalog.markdownFiles(in: gcc + "/" + folder) else { unread.append(folder); continue }
            for path in files {
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
        if unread.count == 3 { throw CatalogError("none of features, conventions or memory/global could be read") }
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
