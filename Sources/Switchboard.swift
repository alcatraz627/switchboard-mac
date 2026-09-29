// Switchboard.swift
// The state behind the Machine tab: what is muted, what is running, what each
// turn costs. Deliberately free of UI code so a headless probe can drive every
// read and every mutation without a GUI.
//
// One rule shapes the whole file: a click may restore a protection, never remove
// one. Re-arming deletes a mute file; muting stays a deliberate `touch` in a
// shell. Suppressing a permission prompt is the single exception and it asks first.

import AppKit
import Foundation

// ── Where state lives ────────────────────────────────────────────────────────

enum SwitchboardPaths {
    /// Overridable so probes can run against a fixture tree instead of the real
    /// config. Everything in this file resolves through it.
    static var gccRoot: String = NSString(string: "~/.claude").expandingTildeInPath
    static var settingsJSON: String { gccRoot + "/settings.json" }
    static var hooksDir: String { gccRoot + "/scripts/hooks" }
}

// ── Guards: mute sentinels ───────────────────────────────────────────────────

struct MutedGuard {
    let sentinel: String        // ".no-review-required"
    let name: String            // "review-required"
    let mutedAt: Date?
}

enum Guards {
    /// Every mute sentinel any hook looks for, discovered by reading the hooks
    /// rather than hard-coding a list that would rot as hooks are added.
    static func knownSentinels() -> [String] {
        var found = Set<String>()
        // Sentinels are not all flat: several hooks read one directory deeper
        // (atone/.gate-off, atone/.add-warn-off), and a missed sentinel is a
        // muted guard that never appears, which is the failure this group exists
        // to prevent. The optional path segment is what catches those.
        let re = try? NSRegularExpression(
            pattern: #"\.claude/((?:[a-z0-9-]+/)?(?:\.(?:no|allow)-[a-z0-9-]+|\.[a-z0-9-]+-(?:off|gate|guard)))"#)
        for path in gateScripts() {
            guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let ns = body as NSString
            re?.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m = m, m.numberOfRanges > 1 {
                    found.insert(ns.substring(with: m.range(at: 1)))
                }
            }
        }
        return found.sorted()
    }

    /// Every script that can honour a mute: hooks, cron gates, and each
    /// adapter's hooks and binaries (the Codex usage gate lives in the last two).
    static func gateScripts() -> [String] {
        let fm = FileManager.default
        let root = SwitchboardPaths.gccRoot
        var dirs = [SwitchboardPaths.hooksDir, root + "/scripts/cron"]
        for a in (try? fm.contentsOfDirectory(atPath: root + "/adapters")) ?? [] {
            dirs += [root + "/adapters/\(a)/hooks", root + "/adapters/\(a)/bin"]
        }
        return dirs.flatMap { d in
            ((try? fm.contentsOfDirectory(atPath: d)) ?? [])
                .filter { $0.hasSuffix(".sh") || $0.hasSuffix(".py") }
                .map { d + "/" + $0 }
        }
    }

    /// Only the sentinels that actually exist, i.e. the guards currently off.
    /// `.allow-fable-subagents` is a deliberate policy lift, not a mute, so it is
    /// excluded: listing it would nag the owner to undo a standing decision.
    static func muted() -> [MutedGuard] {
        let fm = FileManager.default
        return knownSentinels().compactMap { sentinel in
            guard sentinel != ".allow-fable-subagents" else { return nil }
            let path = SwitchboardPaths.gccRoot + "/" + sentinel
            guard fm.fileExists(atPath: path) else { return nil }
            let when = (try? fm.attributesOfItem(atPath: path)[.creationDate]) as? Date
            // A sentinel may carry a directory ("atone/.gate-off"); the readable
            // name comes from the basename with its marker prefix stripped.
            var name = (sentinel as NSString).lastPathComponent
            for prefix in [".no-", ".allow-"] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            if name.hasPrefix(".") { name = String(name.dropFirst()) }
            return MutedGuard(sentinel: sentinel, name: name, mutedAt: when)
        }
    }

    /// Re-arm: delete the sentinel so the hook fires again. The only direction
    /// this file offers. Returns false if the guard was already armed.
    @discardableResult
    static func rearm(_ g: MutedGuard) -> Bool {
        let path = SwitchboardPaths.gccRoot + "/" + g.sentinel
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}

// ── Guards: every gate and its state ─────────────────────────────────────────

/// One gate as the panel lists it: on, muted by a sentinel file, or snoozed
/// through hook-snooze.sh with an expiry and a reason.
struct GateState {
    enum Kind { case on, muted(MutedGuard), snoozed(HookSnooze) }
    let name: String
    let kind: Kind
}

struct HookSnooze {
    let id: String
    let hook: String
    let scope: String
    let until: Date?
    let reason: String
}

enum HookSnoozes {
    static var ledger: String { SwitchboardPaths.gccRoot + "/hooks/snooze.jsonl" }
    static var cli: String { SwitchboardPaths.hooksDir + "/hook-snooze.sh" }

    /// Live rows of the snooze ledger; expired ones are skipped, as the CLI does.
    static func live(now: Date = Date()) -> [HookSnooze] {
        guard let text = try? String(contentsOfFile: ledger, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        var byId: [String: HookSnooze] = [:]
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let hook = o["hook"] as? String else { continue }
            var until: Date?
            if let s = o["until"] as? String { until = iso.date(from: s) }
            else if let n = o["until"] as? NSNumber { until = Date(timeIntervalSince1970: n.doubleValue) }
            if o["lifted"] as? Bool == true { byId[id] = nil; continue }
            if let u = until, u <= now { continue }
            byId[id] = HookSnooze(id: id, hook: hook, scope: o["scope"] as? String ?? "global",
                                  until: until, reason: o["reason"] as? String ?? "")
        }
        return byId.values.sorted { $0.hook < $1.hook }
    }

    /// Lift one snooze through its own CLI, so the ledger stays its format.
    @discardableResult
    static func lift(_ s: HookSnooze) -> Bool {
        guard FileManager.default.fileExists(atPath: cli) else { return false }
        _ = Services.shell("/bin/bash", [cli, "lift", s.id])
        return !live().contains { $0.id == s.id }
    }
}

extension Guards {
    /// Every gate this machine knows of: sentinel gates (on or muted) and
    /// snoozed hooks. Off ones first, then the rest by name.
    static func all() -> [GateState] {
        let muted = Dictionary(muted().map { ($0.sentinel, $0) }, uniquingKeysWith: { a, _ in a })
        var gates: [GateState] = knownSentinels().compactMap { s in
            guard s != ".allow-fable-subagents", !s.contains(".allow-") else { return nil }
            if let m = muted[s] { return GateState(name: m.name, kind: .muted(m)) }
            return GateState(name: displayName(s), kind: .on)
        }
        for z in HookSnoozes.live() {
            gates.removeAll { $0.name == z.hook }
            gates.append(GateState(name: z.hook, kind: .snoozed(z)))
        }
        func off(_ g: GateState) -> Int { if case .on = g.kind { return 1 }; return 0 }
        return gates.sorted { (off($0), $0.name) < (off($1), $1.name) }
    }

    static func displayName(_ sentinel: String) -> String {
        var name = (sentinel as NSString).lastPathComponent
        for prefix in [".no-", ".allow-"] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }
}

// ── Guards: stale push approvals ─────────────────────────────────────────────

struct PushApproval {
    let file: String            // ".push-approved-<uuid>"
    let sessionID: String
    let armedAt: Date?
    /// True when the approving session is no longer live, so the approval is a
    /// loaded gun nobody is holding.
    let sessionIsLive: Bool
}

enum PushApprovals {
    static func armed(liveSessionIDs: Set<String>) -> [PushApproval] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: SwitchboardPaths.gccRoot)
        else { return [] }
        return files.filter { $0.hasPrefix(".push-approved-") }.map { f in
            let sid = String(f.dropFirst(".push-approved-".count))
            let when = (try? fm.attributesOfItem(atPath: SwitchboardPaths.gccRoot + "/" + f)[.creationDate]) as? Date
            return PushApproval(file: f, sessionID: sid, armedAt: when,
                                sessionIsLive: liveSessionIDs.contains(sid))
        }.sorted { ($0.armedAt ?? .distantPast) < ($1.armedAt ?? .distantPast) }
    }

    /// Clear: revoke an approval. Safe in one click because revoking can only
    /// add friction, never remove it.
    @discardableResult
    static func clear(_ a: PushApproval) -> Bool {
        (try? FileManager.default.removeItem(atPath: SwitchboardPaths.gccRoot + "/" + a.file)) != nil
    }
}

// ── settings.json: cost and permission flags ─────────────────────────────────

enum SettingsFlag: String, CaseIterable {
    case alwaysThinking       = "alwaysThinkingEnabled"
    case skipDangerousPrompt  = "skipDangerousModePermissionPrompt"
    case skipAutoPrompt       = "skipAutoPermissionPrompt"
    case skipWorkflowWarning  = "skipWorkflowUsageWarning"

    var label: String {
        switch self {
        case .alwaysThinking:      return "Always thinking"
        case .skipDangerousPrompt: return "Dangerous-mode prompt"
        case .skipAutoPrompt:      return "Auto-permission prompt"
        case .skipWorkflowWarning: return "Workflow usage warning"
        }
    }

    /// True when flipping this ON removes a safeguard. Those three read
    /// inverted in the UI: the row shows whether the PROMPT is on, not whether
    /// the skip is on, because "skip" as a switch label inverts the mental model.
    var isSuppressor: Bool { self != .alwaysThinking }
}

enum Settings {
    /// nil means absent, unreadable, or not a JSON object. Distinct from an
    /// empty object, which is a legitimate config.
    static func readObject() -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: SwitchboardPaths.settingsJSON),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return o
    }

    static func read() -> [String: Any] { readObject() ?? [:] }

    static func bool(_ f: SettingsFlag) -> Bool {
        read()[f.rawValue] as? Bool ?? false
    }

    static func effortLevel() -> String {
        read()["effortLevel"] as? String ?? "unknown"
    }

    static let efforts = ["low", "medium", "high", "xhigh"]

    /// Read-modify-write that keeps every key it did not touch, writes to a
    /// sibling temp file, and swaps atomically, so an interrupted write cannot
    /// leave a half-file where the config belongs. A timestamped backup is kept
    /// because this is the user's global config, not ours.
    @discardableResult
    static func write(key: String, value: Any) -> Bool {
        let path = SwitchboardPaths.settingsJSON
        // Never invent a config: refuse when the file is absent or unreadable.
        // A valid but empty object is a real config and may be written to, which
        // an isEmpty check alone could not tell apart.
        guard FileManager.default.contents(atPath: path) != nil else { return false }
        guard var obj = readObject() else { return false }
        obj[key] = value
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }
        let tmp = path + ".tmp-\(getpid())"
        guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return false }

        // Back up only once the replacement is staged and about to happen, so a
        // write that fails leaves no backup behind.
        let backup = path + backupTag + String(Int(Date().timeIntervalSince1970))
        try? FileManager.default.copyItem(atPath: path, toPath: backup)
        do {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                      withItemAt: URL(fileURLWithPath: tmp))
            pruneBackups()
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: backup)
            return false
        }
    }

    /// Our own backups carry a tag so pruning can never touch the ones other
    /// tools leave beside settings.json (bak-cligating, bak-pushgate, and so on).
    static let backupTag = ".bak-switchboard-"

    static let backupsKept = 5

    private static func pruneBackups() {
        let dir = (SwitchboardPaths.settingsJSON as NSString).deletingLastPathComponent
        let prefix = (SwitchboardPaths.settingsJSON as NSString).lastPathComponent + backupTag
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let mine = all.filter { $0.hasPrefix(prefix) }.sorted()
        guard mine.count > backupsKept else { return }
        for stale in mine.prefix(mine.count - backupsKept) {
            try? FileManager.default.removeItem(atPath: dir + "/" + stale)
        }
    }
}

// ── What new Claude sessions load ────────────────────────────────────────────

/// Switches that shrink what every NEW Claude Code session loads at start.
/// Each writes one documented key in settings.json; a running session keeps
/// what it started with.
enum ContextSwitches {
    /// The claude.ai connectors (Vercel, Linear, Figma, Slack…): their tool
    /// names and instructions otherwise load into every session.
    static let connectorsKey = "disableClaudeAiConnectors"
    /// Plugins whose main payload is a browser-driving MCP server.
    static let browserPlugins = ["playwright@claude-plugins-official", "chrome-devtools-mcp@claude-plugins-official"]

    static func connectorsOn() -> Bool { !(Settings.read()[connectorsKey] as? Bool ?? false) }

    @discardableResult
    static func setConnectors(on: Bool) -> Bool { Settings.write(key: connectorsKey, value: !on) }

    /// Nil when neither browser plugin is installed, so the row can hide.
    static func browserToolsOn() -> Bool? {
        guard let plugins = Settings.read()["enabledPlugins"] as? [String: Any] else { return nil }
        let present = browserPlugins.filter { plugins[$0] != nil }
        guard !present.isEmpty else { return nil }
        return present.contains { plugins[$0] as? Bool ?? false }
    }

    /// Flips only the browser plugins that are installed; every other plugin
    /// entry is written back unchanged.
    @discardableResult
    static func setBrowserTools(on: Bool) -> Bool {
        guard var plugins = Settings.read()["enabledPlugins"] as? [String: Any] else { return false }
        for p in browserPlugins where plugins[p] != nil { plugins[p] = on }
        return Settings.write(key: "enabledPlugins", value: plugins)
    }
}

// ── Services ─────────────────────────────────────────────────────────────────

struct ServiceState {
    let name: String
    let running: Bool
    /// Distinct from `running` on purpose. The hub taught this: a live process on
    /// a listening socket whose advertised address no longer resolves is up and
    /// unreachable at the same time.
    let reachable: Bool
    let detail: String
}

enum Services {
    /// One blocking HTTP probe with a hard cap. Callers must run this off the
    /// main thread; the menu never waits on the network.
    static func probeHTTP(_ urlString: String, timeout: TimeInterval = 1.0) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return ok
    }

    /// The address the hub advertises for phones, read from its own listener
    /// rather than assumed, so a stale tailnet bind is visible.
    static func hubAdvertisedHost() -> String? {
        let out = shell("/usr/sbin/lsof", ["-nP", "-iTCP:5400", "-sTCP:LISTEN"])
        for line in out.split(separator: "\n") {
            guard let tok = line.split(separator: " ").last(where: { $0.contains(":5400") }) else { continue }
            let host = tok.replacingOccurrences(of: ":5400", with: "")
            if host != "127.0.0.1" && host != "*" && !host.isEmpty { return host }
        }
        return nil
    }

    static func pm2Status(_ name: String) -> String? {
        let out = shell("/bin/zsh", ["-lc", "pm2 jlist 2>/dev/null"])
        guard let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for p in arr where p["name"] as? String == name {
            return ((p["pm2_env"] as? [String: Any])?["status"] as? String)
        }
        return nil
    }

    @discardableResult
    static func pm2(_ verb: String, _ name: String) -> Bool {
        _ = shell("/bin/zsh", ["-lc", "pm2 \(verb) \(name)"])
        return true
    }

    /// A command's output only, for callers where an empty answer and a failed
    /// one mean the same thing. Anything that shows the owner a result should
    /// use `run` instead, so a failure never reads as "nothing there".
    static func shell(_ exe: String, _ args: [String], timeout: TimeInterval = 4.0) -> String {
        run(exe, args, timeout: timeout).out
    }

    /// Run a command and say how it went: its output, its exit status, and
    /// whether it could not start or ran out of time.
    ///
    /// A subprocess that wedges would otherwise pin a background thread for every
    /// menu-open and leave the switchboard silently stale, so every call is
    /// capped. Both pipes are drained on other queues: a child that fills the
    /// 64K pipe buffer blocks forever on write if nobody reads it, and then the
    /// timeout never gets a chance to fire.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 4.0) -> ShellResult {
        var r = ShellResult(name: ShellResult.displayName(exe, args), timeout: timeout)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        guard (try? p.run()) != nil else { r.launched = false; return r }

        var out = Data(), err = Data()
        let lock = NSLock()
        let drained = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); if isOut { out = d } else { err = d }; lock.unlock()
                drained.leave()
            }
        }

        if drained.wait(timeout: .now() + timeout) == .timedOut {
            r.timedOut = true
            p.terminate()
            // SIGTERM can be ignored; give it a moment, then take the process out.
            if drained.wait(timeout: .now() + 0.5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = drained.wait(timeout: .now() + 0.5)
            }
            return r
        }
        p.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        r.out = String(data: out, encoding: .utf8) ?? ""
        r.err = String(data: err.suffix(4096), encoding: .utf8) ?? ""
        r.status = p.terminationStatus
        return r
    }
}

/// How one command went. `failure` is the sentence the panel shows when it
/// did not work; nil means it ran and exited cleanly, even with no output.
struct ShellResult {
    var name: String
    var timeout: TimeInterval
    var out = ""
    var err = ""
    var status: Int32? = nil
    var timedOut = false
    var launched = true

    var ok: Bool { launched && !timedOut && status == 0 }

    var failure: String? {
        if !launched { return "\(name) could not be started" }
        if timedOut { return "\(name) took longer than \(Int(timeout)) s and was stopped" }
        guard let s = status, s != 0 else { return nil }
        let line = err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("at ") && !$0.hasPrefix("File \"") }
        return line.map { "\(name): \($0)" } ?? "\(name) stopped with an error (exit \(s))"
    }

    /// The name a person would recognise: the script for `env python3 x.py`,
    /// the first word for `zsh -lc "cmd …"`, else the program itself.
    static func displayName(_ exe: String, _ args: [String]) -> String {
        let base = (exe as NSString).lastPathComponent
        if base == "env", args.first == "python3", args.count > 1 { return (args[1] as NSString).lastPathComponent }
        guard ["zsh", "bash", "sh"].contains(base), let first = args.first else { return base }
        // A login-shell one-liner is named by its first word; an inline `-c`
        // script has no better name than the shell.
        if first == "-lc", args.count > 1 { return String(args[1].split(separator: " ").first ?? Substring(base)) }
        if !first.hasPrefix("-") { return (first as NSString).lastPathComponent }
        return base
    }
}

// ── Warden ───────────────────────────────────────────────────────────────────

enum Warden {
    /// The same sentinel `claude-warden pause` and warden-beat.sh use, so the
    /// CLI, the beat script, and this switch can never disagree about state.
    static var pausedSentinel: String { SwitchboardPaths.gccRoot + "/warden/.paused" }

    /// The institution exists once its charter does; before that, no row.
    static func installed() -> Bool {
        FileManager.default.fileExists(atPath: SwitchboardPaths.gccRoot + "/warden/PROMPT.md")
    }

    static func running() -> Bool {
        installed() && !FileManager.default.fileExists(atPath: pausedSentinel)
    }

    /// The warden's own Claude session, which it rewrites on succession.
    static func currentSession() -> String? {
        let raw = try? String(contentsOfFile: SwitchboardPaths.gccRoot + "/warden/current-session", encoding: .utf8)
        let sid = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sid.isEmpty ? nil : sid
    }

    /// The auto-standdown state: usage-gate says both windows are hot. Distinct
    /// from paused — nothing is written, so a quota reset re-enables by itself.
    /// The manual sentinel always supersedes this in what the row displays.
    static func gated() -> Bool {
        guard FileManager.default.fileExists(atPath: Integrations.usageGate) else { return false }
        return Services.shell("/bin/bash", [Integrations.usageGate]).hasPrefix("GATED")
    }

    /// Pause writes the sentinel with its provenance; resume removes it. Beats
    /// skip BEFORE the delta scan while paused, so activity accumulates and the
    /// first resumed beat judges all of it (catch-up is warden-side, not ours).
    @discardableResult
    static func set(running: Bool) -> Bool {
        let fm = FileManager.default
        if running {
            guard fm.fileExists(atPath: pausedSentinel) else { return false }
            return (try? fm.removeItem(atPath: pausedSentinel)) != nil
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return fm.createFile(atPath: pausedSentinel,
                             contents: Data("via switchboard \(stamp)".utf8))
    }
}

// ── Board sync ───────────────────────────────────────────────────────────────

enum BoardSync {
    static var cli: String { SwitchboardPaths.gccRoot + "/scripts/sync-todos/sync-cli.sh" }

    static func installed() -> Bool { FileManager.default.fileExists(atPath: cli) }

    static func enabled() -> Bool {
        guard FileManager.default.fileExists(atPath: cli) else { return false }
        return Services.shell("/bin/bash", [cli, "status"]).contains("state:        enabled")
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: cli) else { return false }
        _ = Services.shell("/bin/bash", [cli, on ? "enable" : "disable"])
        return true
    }
}
