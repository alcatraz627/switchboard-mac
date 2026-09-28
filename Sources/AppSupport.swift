// AppSupport.swift
// Where Switchboard finds things: its own helpers and state, the log, the
// Claude sessions running right now, and the optional tools it can drive when
// they are installed. Nothing here assumes a particular machine.

import AppKit
import Foundation

// ── The app's own files ─────────────────────────────────────────────────────

enum AppPaths {
    static let home = NSHomeDirectory()

    /// The Python helpers ship inside the bundle (Contents/Resources/lib).
    /// $SWITCHBOARD_LIB overrides it, which is how tests run a helper from the
    /// source tree without building an app.
    static var libDir: String {
        if let env = ProcessInfo.processInfo.environment["SWITCHBOARD_LIB"], !env.isEmpty { return env }
        if let res = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: res + "/lib") {
            return res + "/lib"
        }
        // A bare binary next to the source tree (swiftc during development).
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/lib").path
    }

    static func lib(_ script: String) -> String { libDir + "/" + script }

    /// Saved devices and names. Same rule as Resources/lib/state.py.
    static var stateDir: String {
        let d = ProcessInfo.processInfo.environment["SWITCHBOARD_STATE"]
            ?? home + "/Library/Application Support/Switchboard"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    static let logDir = home + "/Library/Logs/Switchboard"
    static let debugLog = logDir + "/switchboard.log"
    static let debugLogPrev = logDir + "/switchboard.log.1"
}

// ── Logging ──────────────────────────────────────────────────────────────────
// One line per event, size-rotated at 1 MB with one backup kept.

enum LogLevel: String { case info = "INFO", warn = "WARN", error = "ERROR" }

private let logRotateBytes: UInt64 = 1_000_000
private let pidStr = String(ProcessInfo.processInfo.processIdentifier)

private func writeLog(_ level: LogLevel, _ msg: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: AppPaths.logDir, withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: AppPaths.debugLog))?[.size] as? UInt64, size > logRotateBytes {
        try? fm.removeItem(atPath: AppPaths.debugLogPrev)
        try? fm.moveItem(atPath: AppPaths.debugLog, toPath: AppPaths.debugLogPrev)
    }
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(pidStr)] [\(level.rawValue)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: AppPaths.debugLog) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: AppPaths.debugLog))
    }
}

func dlog (_ msg: String) { writeLog(.info,  msg) }
func dwarn(_ msg: String) { writeLog(.warn,  msg) }
func derr (_ msg: String) { writeLog(.error, msg) }

func fmtErr(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain) #\(ns.code): \(ns.localizedDescription)"
}

// ── Changes waiting to be confirmed (drawn by States.swift) ─────────────────

enum Pending {
    /// Most saves finish well inside this, so a fast change never flickers.
    static let showAfter: TimeInterval = 0.35
    /// A change still unconfirmed after this is reported as failed.
    static let giveUpAfter: TimeInterval = 8
}

/// A change the owner asked for that has not been confirmed yet.
struct PendingChange<Value: Equatable>: Equatable {
    let target: Value
    let since: Date
}

// ── Claude sessions running right now ───────────────────────────────────────

/// Claude Code writes one small file per running session to ~/.claude/sessions
/// (<pid>.json with its session id and working directory). A file whose process
/// is gone is a leftover, so liveness is the pid, not the file.
enum LiveSessions {
    struct Session { let pid: Int32; let id: String; let cwd: String }

    static func all() -> [Session] {
        let dir = SwitchboardPaths.gccRoot + "/sessions"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.compactMap { f in
            guard let d = FileManager.default.contents(atPath: dir + "/" + f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value,
                  let id = o["sessionId"] as? String,
                  kill(pid, 0) == 0 || errno == EPERM
            else { return nil }
            return Session(pid: pid, id: id, cwd: o["cwd"] as? String ?? "")
        }
    }

    static func ids() -> Set<String> { Set(all().map { $0.id }) }
    static func dirs() -> [String] { all().map { $0.cwd }.filter { !$0.isEmpty } }
}

// ── Optional tools this app can drive when they are installed ───────────────

/// Each feature that leans on something outside this repo asks here first and
/// hides its row when the answer is no, so a fresh Mac shows a shorter panel
/// rather than broken switches.
enum Integrations {
    private static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    /// Claude Code's own config: settings.json and the live session files.
    static var claudeCode: Bool { exists(SwitchboardPaths.settingsJSON) }
    /// The agent policy store and its CLI (the Agents tab).
    static var policyStore: Bool { exists(PolicyCLI.script) }
    /// Hook scripts that honour mute sentinels (the Guards group).
    static var guardHooks: Bool { exists(SwitchboardPaths.hooksDir) }
    static var kanbanServer: String { SwitchboardPaths.gccRoot + "/scripts/kanban/server.ts" }
    static var kanban: Bool { exists(kanbanServer) }
    /// claude-instances' phone-facing session hub, when that app is installed.
    static var hubScript: String? {
        let candidates = [SwitchboardPaths.gccRoot + "/widgets/claude-instances/lib/hub.sh",
                          AppPaths.home + "/Code/Claude/claude-instances/lib/hub.sh"]
        return candidates.first(where: exists)
    }
    static var usageGate: String { SwitchboardPaths.gccRoot + "/scripts/cron/usage-gate.sh" }
    static var ipcBroker: Bool {
        !Services.shell("/bin/zsh", ["-lc", "command -v claude-ipc"]).isEmpty
    }
}

// ── Preferences carried over from the claude-instances bar ──────────────────

/// Switchboard used to run inside the claude-instances bar and kept its
/// settings in that app's preferences. Copy them across once.
enum PreferenceMigration {
    static let doneKey = "migratedFromClaudeInstances"
    static let keys = ["keepAwakeEnabled", "policyPanel.tab", "codexWarningThreshold",
                       "rateLimitWarningThreshold", "rateLimitDangerThreshold",
                       "switchboard.timers", "ui.fontScale", "appearance.mode", "time.use24h"]

    static func run() {
        let mine = UserDefaults.standard
        guard !mine.bool(forKey: doneKey), let old = UserDefaults(suiteName: "claude-instances-bar") else { return }
        var copied: [String] = []
        for k in keys where mine.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { mine.set(v, forKey: k); copied.append(k) }
        }
        mine.set(true, forKey: doneKey)
        if !copied.isEmpty { dlog("migrated preferences from claude-instances: \(copied.joined(separator: ", "))") }
    }
}
