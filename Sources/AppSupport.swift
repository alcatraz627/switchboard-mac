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

    /// Test runs point SWITCHBOARD_LOG_DIR at a scratch folder, so their lines stay out of the owner's log.
    static let logDir = ProcessInfo.processInfo.environment["SWITCHBOARD_LOG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? home + "/Library/Logs/Switchboard"
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
    /// csync, the owner's tool for driving other machines; the Remote tab shows only with it.
    static var csync: Bool { csyncPath != nil }
    /// Full path, since csync is often not on the PATH a pasted command gets.
    static var csyncPath: String? {
        [AppPaths.home + "/Code/Claude/csync/bin/csync", AppPaths.home + "/.local/bin/csync"].first(where: exists)
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

/// Every symbol that stands for a place in the panel, kept in one map so a
/// tab, its space, its row in Settings and a section header never disagree.
enum Icons {
    /// Tabs, by id. The space bar, the row of tabs under it and Settings all read this.
    static let tab: [String: String] = [
        "agents": "person.badge.shield.checkmark",
        "usage": "gauge.with.dots.needle.67percent",
        "plugins": "puzzlepiece.extension",
        "rules": "checklist",
        "library": "books.vertical",
        "ledger": "list.bullet.clipboard",
        "queue": "tray.full",
        "notes": "note.text",
        "timers": "timer",
        "system": "desktopcomputer",
        "runtime": "bolt.horizontal",
        "controls": "slider.horizontal.3",
        "home": "house",
        "remote": "network.badge.shield.half.filled",
        "settings": "gearshape",
        "approvals": "hand.raised",
    ]

    /// Spaces, by id; none reuses a symbol of a tab inside it.
    static let space: [String: String] = [
        "claude": "sparkle",
        "records": "archivebox",
        "desk": "cup.and.saucer",
        "mac": "laptopcomputer",
        "around": "globe",
    ]

    /// Section headers, by title, wherever the section appears.
    static let section: [String: String] = [
        "Acting as you": "person.wave.2",
        "Code": "chevron.left.forwardslash.chevron.right",
        "Deploy": "icloud.and.arrow.up",
        "Models": "cpu",
        "Machine": "desktopcomputer",
        "Limits": "gauge.with.dots.needle.33percent",
        "Context": "text.badge.minus",
        "Claude": "sparkle",
        "Codex": "terminal",
        "What acts on these numbers": "slider.horizontal.3",
        "Plugins": "puzzlepiece.extension",
        "MCP servers": "server.rack",
        "Project plugins": "puzzlepiece",
        "Project MCP servers": "folder.badge.gearshape",
        "Guards": "shield.lefthalf.filled",
        "Gates": "checkmark.shield",
        "Rules": "checklist",
        "Hook scripts": "link",
        "Skills": "wand.and.stars",
        "Parked skills": "shippingbox",
        "Knowledge": "book.closed",
        "Personas": "theatermasks",
        "Scripts": "terminal",
        "Mistakes": "exclamationmark.bubble",
        "Checkpoints": "bookmark",
        "Open proposals": "lightbulb",
        "Closed proposals": "archivebox",
        "Scheduled": "clock",
        "Cron duties": "repeat",
        "Deploy queue": "icloud.and.arrow.up",
        "Session": "cup.and.saucer",
        "Drives": "externaldrive",
        "Repos": "arrow.triangle.branch",
        "Services": "server.rack",
        "Databases": "cylinder.split.1x2",
        "Dev servers": "network",
        "Local models": "cpu",
        "Schedules": "calendar.badge.clock",
        "Sound": "speaker.wave.2",
        "Display": "sun.max",
        "Wi-Fi": "wifi",
        "Bluetooth": "dot.radiowaves.left.and.right",
        "Lights": "lightbulb.led",
        "Console": "server.rack",
        "Hosts": "laptopcomputer.and.iphone",
        "Feed": "arrow.triangle.2.circlepath",
        "Pushes": "arrow.up.circle",
        "Policy asks": "questionmark.bubble",
        "Approved, waiting to run": "checkmark.circle",
        "Left by ended sessions": "moon.zzz",
        "Tabs": "square.grid.2x2",
        "Hover preview": "cursorarrow.rays",
        "Notes folder": "folder",
    ]
}

/// Moves `dragged` to `target`'s place in an id order.
func reordered(_ order: [String], moving dragged: String, to target: String) -> [String] {
    guard let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target), from != to else { return order }
    var o = order
    o.remove(at: from)
    o.insert(dragged, at: to)
    return o
}

/// Which tabs and sections the owner has hidden in Settings. A hidden one is
/// not drawn and not read: its helper never runs, so hiding saves the work.
enum Visibility {
    static let tabsKey = "switchboard.hiddenTabs"
    static let sectionsKey = "switchboard.hiddenSections"
    static let orderKey = "switchboard.tabOrder"

    /// Related tabs sit together: Claude and its agents, Claude's own records,
    /// your desk, this Mac, the things around it, then Settings and Approvals.
    static let defaultTabOrder = ["agents", "usage", "plugins", "rules", "library",
                                  "ledger", "queue",
                                  "notes", "timers",
                                  "system", "runtime", "controls",
                                  "home", "remote",
                                  "settings", "approvals"]

    /// The spaces along the top of the panel, each holding related tabs.
    /// Settings and Approvals belong to none: they live in the header.
    static let spaces: [(id: String, title: String, icon: String, tabs: [String])] = [
        ("claude", "Claude", ["agents", "usage", "plugins", "rules", "library"]),
        ("records", "Records", ["ledger", "queue"]),
        ("desk", "Desk", ["notes", "timers"]),
        ("mac", "Mac", ["system", "runtime", "controls"]),
        ("around", "Around", ["home", "remote"]),
    ].map { ($0.0, $0.1, Icons.space[$0.0] ?? "square", $0.2) }
    static func space(of tab: String) -> String? { spaces.first { $0.tabs.contains(tab) }?.id }

    /// The tab each space opens on: the one last used in it.
    static let spaceTabKey = "switchboard.spaceTab"
    static func lastTab(in space: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: spaceTabKey) as? [String: String])?[space]
    }
    static func rememberTab(_ tab: String) {
        guard let s = space(of: tab) else { return }
        var d = (UserDefaults.standard.dictionary(forKey: spaceTabKey) as? [String: String]) ?? [:]
        d[s] = tab
        UserDefaults.standard.set(d, forKey: spaceTabKey)
    }

    /// The owner's saved order, with any tab it does not know yet placed after
    /// the tab it follows by default.
    static var tabOrder: [String] {
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        guard !order.isEmpty else { return defaultTabOrder }
        order = order.filter(defaultTabOrder.contains)
        for (i, id) in defaultTabOrder.enumerated() where !order.contains(id) {
            let after = defaultTabOrder[..<i].last { order.contains($0) }
            order.insert(id, at: after.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        return order
    }

    static var hiddenTabs: Set<String> { Set(UserDefaults.standard.stringArray(forKey: tabsKey) ?? []) }
    static var hiddenSections: Set<String> { Set(UserDefaults.standard.stringArray(forKey: sectionsKey) ?? []) }

    static func tabHidden(_ tab: String) -> Bool { hiddenTabs.contains(tab) }
    /// A section of a hidden tab counts as hidden too.
    static func sectionHidden(_ tab: String, _ section: String) -> Bool {
        tabHidden(tab) || hiddenSections.contains(tab + "::" + section)
    }

    /// Section titles hidden on one tab, for a reader to skip.
    static func hiddenTitles(_ tab: String) -> Set<String> {
        Set(hiddenSections.filter { $0.hasPrefix(tab + "::") }.map { String($0.dropFirst(tab.count + 2)) })
    }

    /// Every section a tab can show, for the Settings tab. Tabs not listed
    /// have one body and are shown or hidden whole.
    static let sections: [String: [String]] = [
        "usage": ["Claude", "Codex"],
        "rules": ["Guards", "Rules", "Hook scripts"],
        "ledger": ["Mistakes", "Open proposals", "Closed proposals", "Checkpoints"],
        "queue": ["Scheduled", "Cron duties", "Deploy queue", "Open proposals"],
        "library": ["Skills", "Parked skills", "Knowledge", "Personas", "Scripts"],
        "runtime": ["Services", "Databases", "Dev servers", "Local models", "Schedules"],
        "plugins": ["Plugins", "MCP servers", "Project plugins", "Project MCP servers"],
        "system": ["Session", "Drives", "Repos"],
        "controls": ["Sound", "Display", "Wi-Fi", "Bluetooth"],
        "agents": ["Context"],
    ]

    /// Where each Machine group lives, so a probe can ask whether its section is shown.
    static let groupTab: [String: String] = [
        "Guards": "rules", "Context": "agents",
        "Services": "runtime", "Databases": "runtime", "Dev servers": "runtime", "Local models": "runtime", "Schedules": "runtime",
        "Session": "system", "Drives": "system", "Repos": "system",
    ]

    static func groupHidden(_ title: String) -> Bool { sectionHidden(groupTab[title] ?? "system", title) }
}

/// What the hover preview on the menu bar icon can carry. The owner picks in
/// Settings; the defaults keep it to the three that change what you do next.
enum HoverItem: String, CaseIterable {
    // Claude limits have their own hover page; a saved "limits" is dropped on read
    case approvals, problems, timers, services, iconDot

    var title: String {
        switch self {
        case .approvals: return "Waiting on you"
        case .problems: return "Problems"
        case .timers: return "Running timers"
        case .services: return "Services down"
        case .iconDot: return "Dot on the icon"
        }
    }

    var detail: String {
        switch self {
        case .approvals: return "how many pushes and asks wait, and the oldest"
        case .problems: return "sources that failed to read, failing jobs, hooks with no event"
        case .timers: return "up to two running timers, timed flips such as Keep Awake, and the next note reminder"
        case .services: return "kanban, the session hub or the ipc broker when down"
        case .iconDot: return "a dot on the menu bar icon: yellow while something waits on you, red while something is broken"
        }
    }

    static let key = "switchboard.hoverItems"
    static let defaults: Set<HoverItem> = [.approvals, .problems, .timers]

    static var chosen: Set<HoverItem> {
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return defaults }
        return Set(raw.compactMap(HoverItem.init(rawValue:)))
    }
}

/// A menu bar app has no menu bar of its own, and macOS routes ⌘A, ⌘X, ⌘C,
/// ⌘V and ⌘Z to text fields through the Edit menu. An Edit menu that is never
/// shown gives every field in the panel those keys.
enum EditMenu {
    static func install() {
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Switchboard", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

/// What a reading from outside the app is: waiting for its first value, a
/// value with its age, a value that could not be refreshed, no value because
/// reading failed, or nothing to read because the source is absent.
/// Drawn by `ReadingStatus` in States.swift.
enum ReadingState: Equatable {
    case loading
    case fresh(Date)
    case stale(Date, String)
    case failed(String)
    case unavailable(String)

    var isFailure: Bool { if case .failed = self { return true }; return false }
    var canRetry: Bool { if case .unavailable = self { return false }; if case .loading = self { return false }; return true }
}
