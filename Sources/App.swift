// App.swift
// The Switchboard app: one menu bar icon whose panel holds this Mac's switches.
// This file owns the Machine tab's rows (guards, services, schedules, keep
// awake, wake-on-LAN) and the timers that flip a switch back later; the other
// tabs own their own state (see SwitchboardConcerns in PolicyPanel.swift).

import AppKit
import Foundation
import IOKit.pwr_mgt

final class SwitchboardApp: NSObject, NSApplicationDelegate {
    private var policyController: PolicyStatusController?
    private var systemTimerTick: Timer?
    private var sbSnapshot = SBSnapshot()

    /// Keep Awake holds a power assertion so the SYSTEM stays awake while the
    /// display still sleeps and locks. Saved, so it survives a restart.
    private let keepAwakeKey = "keepAwakeEnabled"
    private(set) var keepAwakeOn = false
    private var keepAwakeAssertionID: IOPMAssertionID = 0

    private var kanbanUp: Bool?
    private var kanbanBusy = false

    // ── Lifecycle ────────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ note: Notification) {
        dlog("─── switchboard starting (pid \(getpid()), lib \(AppPaths.libDir)) ───")
        PreferenceMigration.run()
        killOtherInstances()
        if UserDefaults.standard.bool(forKey: keepAwakeKey) { setKeepAwake(true) }

        policyController = PolicyStatusController(
            liveDirs: { LiveSessions.dirs() },
            requestSystemRefresh: { [weak self] in self?.refreshSnapshot() })
        if let store = policyController?.store {
            store.startSystemTimer = { [weak self] k, until in self?.startSystemTimer(k, until: until) }
            store.cancelSystemTimer = { [weak self] k in self?.cancelSystemTimer(k) }
            store.endSystemTimerNow = { [weak self] k in self?.endSystemTimerNow(k) }
        }
        systemTimerTick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.fireDueSystemTimers()
        }
        // Probe once shortly after launch so the Machine tab has rows before
        // the first open instead of loading while the owner watches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshSnapshot() }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.policyController?.show() }
        }
    }

    func applicationWillTerminate(_ note: Notification) { dlog("terminating") }

    /// Only one Switchboard at a time: a second icon would fight the first
    /// over the same timers and power assertion. A headless run (--dump,
    /// --snapshot…) shows no icon and exits on its own, so it is left alone.
    private func killOtherInstances() {
        let name = ProcessInfo.processInfo.processName
        let out = Services.shell("/usr/bin/pgrep", ["-x", name])
        let others = out.split(separator: "\n").compactMap { Int32($0) }.filter { pid in
            guard pid != getpid() else { return false }
            let args = Services.shell("/bin/ps", ["-o", "args=", "-p", String(pid)])
            return !args.contains(" --")
        }
        others.forEach { kill($0, SIGTERM) }
        if !others.isEmpty {
            dlog("dedupe: stopped \(others.count) older instance(s)")
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // ── Keep Awake ───────────────────────────────────────────────────────────

    func setKeepAwake(_ on: Bool) {
        if on {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Switchboard: Keep Awake" as CFString, &id)
            keepAwakeOn = rc == kIOReturnSuccess
            if keepAwakeOn { keepAwakeAssertionID = id }
            dlog(keepAwakeOn ? "keep-awake ON (assertion \(id))" : "keep-awake assertion FAILED rc=\(rc)")
        } else {
            if keepAwakeAssertionID != 0 {
                IOPMAssertionRelease(keepAwakeAssertionID)
                keepAwakeAssertionID = 0
            }
            keepAwakeOn = false
            dlog("keep-awake OFF")
        }
        UserDefaults.standard.set(keepAwakeOn, forKey: keepAwakeKey)
    }

    // ── Rows ─────────────────────────────────────────────────────────────────
    // A click may restore a protection, never remove one; suppressing a
    // permission prompt is the single exception and it asks first.

    enum SBBadge {
        case on(NSColor), off, count(Int, NSColor), ok
        var text: String {
            switch self {
            case .on: return "on"
            case .off: return "off"
            case .count(let n, _): return "\(n)"
            case .ok: return "ok"
            }
        }
        /// nil renders the hollow form, which is what "nothing engaged" looks like.
        var tint: NSColor? {
            switch self {
            case .on(let c), .count(_, let c): return c
            case .off, .ok: return nil
            }
        }
    }

    struct SBRow {
        let label: String
        let badge: SBBadge
        let note: String
        var enabled: Bool = true
        var onClick: (() -> Void)? = nil
        var submenu: (() -> NSMenu)? = nil
        var tip: String = ""
        var link: String? = nil
        var children: [SystemRow] = []
    }

    /// Everything the rows render, read off the main thread in one pass.
    struct SBSnapshot {
        var muted: [MutedGuard] = []
        var gates: [GateState] = []
        var approvals: [PushApproval] = []
        var prompts: [SettingsFlag: Bool] = [:]
        var boardSync = false
        var hubReachable: Bool? = nil
        /// The advertised (phone) address can be dead while localhost serves.
        var hubLocal: Bool? = nil
        var hubHost: String? = nil
        var brokerUp: Bool? = nil
        var decisionPages: String? = nil
        var wardenRunning: Bool? = nil
        var wardenGated = false
        var wardenGatePct = 90
        var awakeHolders: [String] = []
        var connectorsOn: Bool? = nil
        var browserToolsOn: Bool? = nil
        var jobs: [[String: Any]] = []
        var wolTargets: [[String: Any]] = []
    }

    /// Refresh the slow half off the main thread. The panel shows whatever
    /// the last snapshot held and never waits on a probe.
    func refreshSnapshot(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var s = SBSnapshot()
            if Integrations.guardHooks {
                s.muted = Guards.muted()
                s.gates = Guards.all()
            }
            s.approvals = PushApprovals.armed(liveSessionIDs: LiveSessions.ids())
            if Integrations.claudeCode {
                for f in SettingsFlag.allCases { s.prompts[f] = Settings.bool(f) }
                s.connectorsOn = ContextSwitches.connectorsOn()
                s.browserToolsOn = ContextSwitches.browserToolsOn()
            }
            s.boardSync = BoardSync.enabled()
            if Integrations.hubScript != nil {
                s.hubHost = Services.hubAdvertisedHost()
                s.hubLocal = Services.probeHTTP("http://127.0.0.1:5400/healthz")
                s.hubReachable = s.hubHost.map { Services.probeHTTP("http://\($0):5400/healthz") } ?? s.hubLocal
            }
            if Integrations.ipcBroker {
                s.brokerUp = Services.shell("/bin/zsh", ["-lc", "claude-ipc daemon status 2>/dev/null"]).contains("up")
            }
            s.decisionPages = Services.pm2Status("decision-pages")
            s.wardenRunning = Warden.installed() ? Warden.running() : nil
            if s.wardenRunning == true {
                s.wardenGated = Warden.gated()
                if let n = Int(PolicyCLI.run(["get", "ops.usage_gate_pct"]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)) { s.wardenGatePct = n }
            }
            let kanban = Integrations.kanban ? Services.probeHTTP("http://127.0.0.1:5106/api/boards") : nil
            s.awakeHolders = Self.sleepHolders()
            func pyList(_ script: String) -> [[String: Any]] {
                let out = Services.shell("/usr/bin/env", ["python3", AppPaths.lib(script), "list"], timeout: 8)
                return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]) ?? []
            }
            s.jobs = pyList("jobs.py")
            s.wolTargets = pyList("wol.py")
            DispatchQueue.main.async {
                self?.sbSnapshot = s
                if self?.kanbanBusy == false { self?.kanbanUp = kanban }
                self?.refreshPanel()
                completion?()
            }
        }
    }

    /// Other processes holding the Mac awake: pmset's per-process list, minus
    /// macOS's own daemons and this app. A caffeinate is named by the process
    /// it runs for, so "node" rather than "caffeinate".
    static func sleepHolders() -> [String] {
        var holders: [String] = []
        let me = ProcessInfo.processInfo.processName
        let lines = Services.shell("/usr/bin/pmset", ["-g", "assertions"]).split(separator: "\n").map(String.init)
        for (i, line) in lines.enumerated() {
            guard line.contains("PreventUserIdleSystemSleep") || line.contains("PreventSystemSleep"),
                  let open = line.range(of: "("), let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
            else { continue }
            var name = String(line[open.upperBound..<close.lowerBound])
            if name == me || (name.hasSuffix("d") && name == name.lowercased()
                && !name.contains("-") && name.count > 4) { continue }
            if name == "caffeinate", i + 1 < lines.count, let behalf = lines[i + 1].range(of: "on behalf of '") {
                name = (String(lines[i + 1][behalf.upperBound...].prefix { $0 != "'" }) as NSString).lastPathComponent
            } else if name == "caffeinate" {
                name = "claude"   // Claude Code's rolling caffeinate carries no "on behalf of"
            }
            if !holders.contains(name) { holders.append(name) }
        }
        return holders
    }

    private func guardRows() -> [SBRow] {
        guard Integrations.guardHooks || Integrations.claudeCode else { return [] }
        let s = sbSnapshot
        let stale = s.approvals.filter { !$0.sessionIsLive }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        var rows: [SBRow] = []

        // Every gate, opened inside the card: off ones first with the one
        // action that restores them, then the ones that are on.
        if Integrations.guardHooks && !s.gates.isEmpty {
            let offCount = s.gates.filter { if case .on = $0.kind { return false }; return true }.count
            // The gates that are on fold into one row of their own: 60-odd
            // green rows would bury the few that need attention.
            var onRows: [SystemRow] = []
            var children: [SystemRow] = s.gates.compactMap { g in
                switch g.kind {
                case .on:
                    var r = SystemRow(label: g.name, state: .on(menuGreen), note: "on", tip: "This gate is armed.")
                    r.key = "gate-on-" + g.name
                    onRows.append(r)
                    return nil
                case .muted(let m):
                    var r = SystemRow(label: g.name, state: .off,
                                      note: m.mutedAt.map { "muted since \(f.string(from: $0))" } ?? "muted",
                                      tip: "Switched off by ~/.claude/\(m.sentinel). Re-arm deletes that file; muting again stays a deliberate act in a shell.",
                                      action: { [weak self] in Guards.rearm(m); self?.refreshSnapshot() })
                    r.buttonLabel = "Re-arm"
                    return r
                case .snoozed(let z):
                    var r = SystemRow(label: g.name, state: .off,
                                      note: "snoozed" + (z.until.map { " until \(f.string(from: $0))" } ?? "")
                                          + (z.scope == "global" ? "" : " · \(z.scope)"),
                                      tip: z.reason.isEmpty ? "Snoozed through hook-snooze.sh." : z.reason,
                                      action: { [weak self] in HookSnoozes.lift(z); self?.refreshSnapshot() })
                    r.buttonLabel = "Lift"
                    return r
                }
            }
            if !onRows.isEmpty {
                var on = SystemRow(label: "\(onRows.count) on", state: .count(onRows.count, menuGreen),
                                   note: "armed and working", tip: "Every gate that is armed. Click to list them.")
                on.key = "gates-on"
                on.children = onRows
                children.append(on)
            }
            rows.append(SBRow(label: "Gates", badge: offCount == 0 ? .ok : .count(offCount, menuYellow),
                              note: offCount == 0 ? "all \(s.gates.count) on" : "\(offCount) off · \(s.gates.count - offCount) on",
                              tip: "Every hook gate: on, muted by a file, or snoozed with an expiry. Click to open.",
                              children: children))
        }

        // The prompt, not the skip: "on" always means the safer state.
        if Integrations.claudeCode {
            let flags = SettingsFlag.allCases.filter { $0.isSuppressor }
            let suppressed = flags.filter { s.prompts[$0] ?? false }
            let children: [SystemRow] = flags.map { flag in
                let off = s.prompts[flag] ?? false
                return SystemRow(label: flag.label, state: off ? .off : .on(menuGreen),
                                 note: off ? "suppressed" : "asks first",
                                 tip: off ? "Turn on to bring this confirmation back."
                                          : "This prompt is active. Turning it off asks for confirmation first.",
                                 action: { [weak self] in self?.togglePrompt(flag, suppressed: off) })
            }
            rows.append(SBRow(label: "Permission prompts",
                              badge: suppressed.isEmpty ? .ok : .count(suppressed.count, menuYellow),
                              note: suppressed.isEmpty ? "all ask first" : "\(suppressed.count) suppressed in settings.json",
                              tip: "Claude Code's confirmation prompts. Click to open.",
                              children: children))
        }
        if !stale.isEmpty {
            rows.append(SBRow(label: "Push approvals", badge: .count(stale.count, menuYellow),
                              note: approvalNote(stale.first),
                              onClick: { [weak self] in
                                  stale.forEach { PushApprovals.clear($0) }
                                  self?.refreshSnapshot()
                              },
                              tip: "Push approvals armed by sessions that are no longer live. Click to revoke them."))
        }
        return rows
    }

    private func approvalNote(_ a: PushApproval?) -> String {
        guard let when = a?.armedAt else { return a == nil ? "armed" : "dead session" }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return "armed \(f.string(from: when)), dead session"
    }

    private func serviceRows() -> [SBRow] {
        let s = sbSnapshot
        var rows: [SBRow] = []

        if Integrations.kanban {
            let note = kanbanBusy ? "working…" : kanbanUp == nil ? "probing…" : kanbanUp! ? "serving :5106" : "not running"
            rows.append(SBRow(label: "Kanban Board", badge: kanbanUp == true ? .on(menuGreen) : .off, note: note,
                              enabled: !kanbanBusy, onClick: { [weak self] in self?.toggleKanban() },
                              tip: "The kanban board server on port 5106. It stays off across reboots; this switch is where it comes back.",
                              link: kanbanUp == true ? "http://localhost:5106" : nil))
        }

        if let hub = Integrations.hubScript {
            // Reachability, not just liveness: a listener on a tailnet address
            // that no longer resolves is up and unreachable at once.
            let ok = s.hubReachable == true
            let note = s.hubReachable == nil ? "probing…" : ok ? "serving :5400"
                : s.hubHost != nil ? "up, \(s.hubHost!) unreachable" : "not running"
            rows.append(SBRow(label: "Session Hub", badge: ok ? .on(menuGreen) : .off, note: note,
                              onClick: { [weak self] in
                                  let up = ok
                                  DispatchQueue.global(qos: .utility).async {
                                      _ = Services.shell("/bin/bash", [hub, up ? "stop" : "restart"])
                                      DispatchQueue.main.async { self?.refreshSnapshot() }
                                  }
                              },
                              tip: "claude-instances' phone-facing session hub on port 5400. Restart it after Tailscale reconnects.",
                              link: s.hubLocal == true ? "http://localhost:5400" : nil))
        }

        if let up = s.brokerUp {
            rows.append(SBRow(label: "ipc Broker", badge: up ? .on(menuGreen) : .off, note: up ? "up" : "down",
                              enabled: false, tip: "The cross-session message broker. Read-only here: it runs under launchd."))
        }

        if let dp = s.decisionPages {
            rows.append(SBRow(label: "Decision Pages", badge: dp == "online" ? .on(menuGreen) : .off,
                              note: dp == "online" ? "serving :5197" : "pm2, \(dp)",
                              onClick: { [weak self] in
                                  Services.pm2(dp == "online" ? "stop" : "start", "decision-pages")
                                  self?.refreshSnapshot()
                              },
                              tip: "The decision-page server used for batched human feedback.",
                              link: dp == "online" ? "http://localhost:5197" : nil))
        }

        if let wr = s.wardenRunning {
            rows.append(SBRow(label: "Warden",
                              badge: !wr ? .off : (s.wardenGated ? .on(menuYellow) : .on(menuGreen)),
                              note: !wr ? "paused by you, deltas held"
                                  : (s.wardenGated ? "standing down, usage >\(s.wardenGatePct)% (auto-resumes)" : "beats live"),
                              onClick: { [weak self] in Warden.set(running: !wr); self?.refreshSnapshot() },
                              tip: "The session warden. Click toggles YOUR pause. The yellow standing-down state is the usage gate; it clears itself when a window reopens."))
        }
        return rows
    }

    private func sessionRows() -> [SBRow] {
        var rows = [SBRow(label: "Keep Awake", badge: keepAwakeOn ? .on(menuTeal) : .off,
                          note: keepAwakeOn ? "sleep blocked"
                              : (sbSnapshot.awakeHolders.isEmpty ? "system may sleep"
                                 : "also held awake by " + sbSnapshot.awakeHolders.joined(separator: ", ")),
                          onClick: { [weak self] in
                              guard let self = self else { return }
                              self.setKeepAwake(!self.keepAwakeOn)
                              self.refreshPanel()
                          },
                          tip: "Prevent idle system sleep so remote sessions stay connected on battery. The display still sleeps and locks normally.")]
        if BoardSync.installed() {
            rows.append(SBRow(label: "Board sync", badge: sbSnapshot.boardSync ? .on(menuGreen) : .off,
                              note: sbSnapshot.boardSync ? "todos to kanban" : "hooks skip",
                              onClick: { [weak self] in
                                  BoardSync.set(!(self?.sbSnapshot.boardSync ?? false))
                                  self?.refreshSnapshot()
                              },
                              tip: "Whether session hooks sync the todo list to the kanban board."))
        }
        return rows
    }

    /// What every new Claude session loads. Changes apply from the next new
    /// session; a running one keeps what it started with.
    private func contextRows() -> [SBRow] {
        var rows: [SBRow] = []
        if let on = sbSnapshot.connectorsOn {
            rows.append(SBRow(label: "claude.ai connectors", badge: on ? .on(menuGreen) : .off,
                              note: on ? "load in new sessions" : "off from the next new session",
                              onClick: { [weak self] in
                                  ContextSwitches.setConnectors(on: !on)
                                  self?.refreshSnapshot()
                              },
                              tip: "Vercel, Linear, Figma, Slack and the other claude.ai connectors. Off keeps their tool names and instructions out of every new session. Sets disableClaudeAiConnectors in ~/.claude/settings.json."))
        }
        if let on = sbSnapshot.browserToolsOn {
            rows.append(SBRow(label: "Browser tools", badge: on ? .on(menuGreen) : .off,
                              note: on ? "Playwright, Chrome DevTools" : "off from the next new session",
                              onClick: { [weak self] in
                                  ContextSwitches.setBrowserTools(on: !on)
                                  self?.refreshSnapshot()
                              },
                              tip: "The Playwright and Chrome DevTools plugins, whose browser MCP servers load into every new session. Turning them off also hides their skills."))
        }
        return rows
    }

    // ── Permission prompts ───────────────────────────────────────────────────

    private func togglePrompt(_ flag: SettingsFlag, suppressed: Bool) {
        if suppressed {
            Settings.write(key: flag.rawValue, value: false)
            refreshSnapshot()
            return
        }
        let a = NSAlert()
        a.messageText = "Suppress the \(flag.label.lowercased())?"
        a.informativeText = "This removes a confirmation step for every session on this machine, not just this one."
        a.alertStyle = .warning
        a.addButton(withTitle: "Suppress")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Settings.write(key: flag.rawValue, value: true)
        refreshSnapshot()
    }

    // ── The Machine tab ──────────────────────────────────────────────────────

    /// Hand the panel a fresh set of rows. Hops a tick because a row can
    /// trigger this from inside its own click handler.
    private func refreshPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.policyController?.store.systemGroups = self.panelSystemGroups()
        }
    }

    func panelSystemGroups() -> [SystemGroup] {
        func convert(_ r: SBRow) -> SystemRow {
            let state: SystemRow.State
            switch r.badge {
            case .on(let c): state = .on(c)
            case .off: state = .off
            case .count(let n, let c): state = .count(n, c)
            case .ok: state = .ok
            }
            var row = SystemRow(label: r.label, state: state, note: r.note, enabled: r.enabled,
                                tip: r.tip, link: r.link, action: r.onClick, menu: r.submenu)
            row.children = r.children
            if row.isSwitch && r.enabled {
                row.timerKey = r.label
                row.timer = systemTimers[r.label]
            }
            return row
        }
        var out: [SystemGroup] = []
        for (title, rows) in [("Guards", guardRows()), ("Context", contextRows()), ("Services", serviceRows())] where !rows.isEmpty {
            out.append(SystemGroup(title: title, rows: rows.map(convert)))
        }
        let schedules = scheduleRows()
        if !schedules.isEmpty { out.append(SystemGroup(title: "Schedules", rows: schedules)) }
        out.append(SystemGroup(title: "Session", rows: sessionRows().map(convert) + [wakeOnLANRow()]))
        return out
    }

    /// The Machine tab as text, for checking the rows without a screen.
    func dumpSwitchboard() -> String {
        let groups = panelSystemGroupsFresh()
        var out = ["SWITCHBOARD DUMP"]
        for g in groups {
            out.append("\n\(g.title.uppercased())")
            for r in g.rows {
                let badge: String
                switch r.state {
                case .on: badge = "[on]"
                case .off: badge = "(off)"
                case .count(let n, _): badge = "[\(n)]"
                case .ok: badge = "(ok)"
                }
                let affordance = r.menu != nil ? "submenu" : (r.action != nil ? "click" : "readonly")
                out.append(String(format: "  %-20@ %-6@ %-28@ %@%@", r.label as NSString, badge as NSString,
                                  r.note as NSString, affordance as NSString, (r.enabled ? "" : " disabled") as NSString))
                if let link = r.link { out.append("      link: \(link)") }
                for c in r.children {
                    let cb: String
                    switch c.state {
                    case .on: cb = "[on]"; case .off: cb = "(off)"
                    case .count(let n, _): cb = "[\(n)]"; case .ok: cb = "(ok)"
                    }
                    out.append(String(format: "      · %-26@ %-6@ %@%@", c.label as NSString, cb as NSString,
                                      c.note as NSString, (c.buttonLabel.map { "  [\($0)]" } ?? "") as NSString))
                }
            }
        }
        out.append("\nsnapshot: muted=\(sbSnapshot.muted.count) approvals=\(sbSnapshot.approvals.count) "
                   + "jobs=\(sbSnapshot.jobs.count) wol=\(sbSnapshot.wolTargets.count) lib=\(AppPaths.libDir)")
        return out.joined(separator: "\n")
    }

    /// Fresh rows for a headless run: same probe the panel uses, waited on by
    /// pumping the runloop the probe completes on.
    func panelSystemGroupsFresh() -> [SystemGroup] {
        var done = false
        refreshSnapshot { done = true }
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return panelSystemGroups()
    }

    // ── Schedules: launchd jobs ──────────────────────────────────────────────

    private func scheduleRows() -> [SystemRow] {
        let jobs = sbSnapshot.jobs
        guard !jobs.isEmpty else { return [] }
        let script = AppPaths.lib("jobs.py")
        func jobMenu(_ j: [String: Any]) -> NSMenu {
            let m = NSMenu()
            let label = j["label"] as? String ?? ""
            m.addItem(ClosureMenuItem("Run now") { [weak self] in
                _ = Services.shell("/usr/bin/env", ["python3", script, "run", label])
                self?.refreshSnapshot()
            })
            if let plist = j["plist"] as? String {
                m.addItem(ClosureMenuItem("Show plist in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)])
                })
            }
            if let log = j["log"] as? String {
                m.addItem(ClosureMenuItem("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) })
            }
            m.addItem(.separator())
            let info = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
            return m
        }
        // Always-on agents are services, not schedules: one summary row. Only
        // failing scheduled jobs earn a row of their own.
        let always = jobs.filter { ($0["schedule"] as? String) == "always running" }
        let timed = jobs.filter { ($0["schedule"] as? String) != "always running" }
        let healthy = timed.filter { !($0["failing"] as? Bool ?? false) }
        var rows: [SystemRow] = []
        if !always.isEmpty {
            let down = always.filter { ($0["loaded"] as? Bool ?? false) && !($0["running"] as? Bool ?? false) }
            let running = always.filter { $0["running"] as? Bool ?? false }.count
            let unloaded = always.filter { !($0["loaded"] as? Bool ?? false) }.count
            var r = SystemRow(label: "Always-on agents",
                              state: down.isEmpty ? .count(running, menuGreen) : .count(down.count, menuRed),
                              note: (down.isEmpty ? "\(running) running" : "\(down.count) stopped")
                                  + (unloaded > 0 ? " · \(unloaded) not loaded" : ""),
                              tip: "Agents launchd keeps alive. Pick one for its actions.",
                              menu: {
                                  let m = NSMenu()
                                  for j in always {
                                      let item = NSMenuItem(title: "\(j["running"] as? Bool ?? false ? "●" : "○")  \(j["name"] as? String ?? "?")", action: nil, keyEquivalent: "")
                                      item.submenu = jobMenu(j)
                                      m.addItem(item)
                                  }
                                  return m
                              })
            r.key = "always-on-agents"
            rows.append(r)
        }
        if !healthy.isEmpty {
            var r = SystemRow(label: "Scheduled jobs", state: .count(healthy.count, menuGreen),
                              note: "last runs ok · pick one for run now, plist, log",
                              tip: "launchd jobs that run on a clock.",
                              menu: {
                                  let m = NSMenu()
                                  for j in healthy {
                                      let item = NSMenuItem(title: "\(j["name"] as? String ?? "?")  ·  \(j["schedule"] as? String ?? "")", action: nil, keyEquivalent: "")
                                      item.submenu = jobMenu(j)
                                      m.addItem(item)
                                  }
                                  return m
                              })
            r.key = "scheduled-jobs"
            rows.append(r)
        }
        for j in timed where j["failing"] as? Bool ?? false {
            let exit = (j["last_exit"] as? NSNumber)?.intValue ?? 1
            var r = SystemRow(label: (j["name"] as? String ?? "?").capitalized, state: .count(exit, menuRed),
                              note: (j["schedule"] as? String ?? "") + " · last run failed (exit \(exit))",
                              tip: j["label"] as? String ?? "", menu: { jobMenu(j) })
            r.key = j["label"] as? String
            rows.append(r)
        }
        return rows
    }

    // ── Wake-on-LAN ──────────────────────────────────────────────────────────

    private func wakeOnLANRow() -> SystemRow {
        let targets = sbSnapshot.wolTargets
        let wol = AppPaths.lib("wol.py")
        return SystemRow(
            label: "Wake a device",
            state: targets.isEmpty ? .off : .count(targets.count, menuTeal),
            note: targets.isEmpty ? "no saved devices" : targets.compactMap { $0["name"] as? String }.joined(separator: ", "),
            tip: "Send a wake-on-LAN packet to a saved machine on the home network.",
            menu: { [weak self] in
                let m = NSMenu()
                for t in targets {
                    let name = t["name"] as? String ?? "?", mac = t["mac"] as? String ?? ""
                    let bcast = t["broadcast"] as? String ?? "255.255.255.255"
                    m.addItem(ClosureMenuItem("Wake \(name)") {
                        let r = Services.shell("/usr/bin/env", ["python3", wol, "wake", mac, bcast])
                        dlog("wol: \(name) \(r.trimmingCharacters(in: .whitespacesAndNewlines))")
                    })
                }
                if !targets.isEmpty { m.addItem(.separator()) }
                m.addItem(ClosureMenuItem("Add device…") { self?.addWakeTarget(wol) })
                if !targets.isEmpty {
                    let forget = NSMenuItem(title: "Forget", action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    for t in targets {
                        let mac = t["mac"] as? String ?? ""
                        sub.addItem(ClosureMenuItem(t["name"] as? String ?? mac) {
                            _ = Services.shell("/usr/bin/env", ["python3", wol, "remove", mac])
                            self?.refreshSnapshot()
                        })
                    }
                    forget.submenu = sub
                    m.addItem(forget)
                }
                return m
            })
    }

    private func addWakeTarget(_ wol: String) {
        let a = NSAlert()
        a.messageText = "Add a device to wake"
        a.informativeText = "Its MAC address, for example 3c:22:fb:12:34:56. The machine must have wake-on-LAN turned on."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        name.placeholderString = "Name (e.g. Desktop PC)"
        let mac = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        mac.placeholderString = "MAC address"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(name); box.addSubview(mac)
        a.accessoryView = box
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = Services.shell("/usr/bin/env", ["python3", wol, "add", name.stringValue, mac.stringValue])
        if r.contains("error") {
            let e = NSAlert(); e.messageText = "Not saved"; e.informativeText = r; e.runModal()
        }
        refreshSnapshot()
    }

    // ── Timed flips ──────────────────────────────────────────────────────────
    // "Keep Awake for 2 hours": flip now, flip back at a time. At the due time
    // the switch is re-probed and flipped only if it is not already where it
    // should be, so a manual change in between is never undone twice.

    /// Overridden by the timer probe, so a test never touches live timers.
    var systemTimersKey = "switchboard.timers"

    var systemTimers: [String: SystemTimer] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: systemTimersKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { d in
                guard let t = d["until"] as? Double, let on = d["restoreOn"] as? Bool else { return nil }
                return SystemTimer(until: Date(timeIntervalSince1970: t), restoreOn: on)
            }
        }
        set {
            let raw = newValue.mapValues { ["until": $0.until.timeIntervalSince1970, "restoreOn": $0.restoreOn] as [String: Any] }
            UserDefaults.standard.set(raw, forKey: systemTimersKey)
        }
    }

    private func systemRow(_ key: String) -> SystemRow? {
        panelSystemGroups().flatMap { $0.rows }.first { $0.timerKey == key }
    }

    func startSystemTimer(_ key: String, until: Date) {
        guard let row = systemRow(key), until > Date() else { return }
        // Re-timing keeps the original restore state.
        let restore = systemTimers[key]?.restoreOn ?? row.isOn
        if row.isOn == restore { row.action?() }
        systemTimers[key] = SystemTimer(until: until, restoreOn: restore)
        dlog("timer: \(key) until \(until), then \(restore ? "on" : "off")")
        refreshPanel()
    }

    func cancelSystemTimer(_ key: String) {
        systemTimers[key] = nil
        refreshPanel()
    }

    func endSystemTimerNow(_ key: String) {
        guard let t = systemTimers[key] else { return }
        systemTimers[key] = nil
        if let row = systemRow(key), row.isOn != t.restoreOn { row.action?() }
        refreshSnapshot()
    }

    private func fireDueSystemTimers() {
        let due = systemTimers.filter { $0.value.until <= Date() }
        guard !due.isEmpty else { return }
        refreshSnapshot { [weak self] in
            guard let self = self else { return }
            for (key, t) in due {
                self.systemTimers[key] = nil
                if let row = self.systemRow(key), row.isOn != t.restoreOn {
                    dlog("timer: \(key) due, turning \(t.restoreOn ? "on" : "off")")
                    row.action?()
                } else {
                    dlog("timer: \(key) due, already \(t.restoreOn ? "on" : "off")")
                }
            }
            self.refreshSnapshot()
        }
    }

    /// Headless check of the timer engine on the real Keep Awake switch, with
    /// the power assertion read back from pmset. Leaves Keep Awake as it was.
    func probeSystemTimers() -> String {
        systemTimersKey = "switchboard.timers.probe"
        systemTimers = [:]
        var lines: [String] = [], fails = 0
        func check(_ name: String, _ ok: Bool) { lines.append("  \(ok ? "ok  " : "FAIL") \(name)"); if !ok { fails += 1 } }
        func pump(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func asserted() -> Bool {
            Services.shell("/usr/bin/pmset", ["-g", "assertions"])
                .split(separator: "\n").contains { $0.contains("pid \(getpid())(") && $0.contains("PreventUserIdleSystemSleep") }
        }
        func fire() {
            fireDueSystemTimers()
            let deadline = Date().addingTimeInterval(25)
            while systemTimers.values.contains(where: { $0.until <= Date() }) && Date() < deadline { pump(0.1) }
            pump(0.5)
        }
        let before = keepAwakeOn
        if keepAwakeOn { setKeepAwake(false) }
        let key = "Keep Awake"

        startSystemTimer(key, until: Date().addingTimeInterval(2)); pump(0.3)
        check("on-for-a-while turns Keep Awake on", keepAwakeOn)
        check("the power assertion is really held", asserted())
        check("timer recorded to restore off", systemTimers[key]?.restoreOn == false)
        pump(2.2); fire()
        check("at the due time it turns back off", !keepAwakeOn)
        check("the power assertion is released", !asserted())
        check("the timer is gone", systemTimers[key] == nil)

        startSystemTimer(key, until: Date().addingTimeInterval(2)); pump(0.3)
        setKeepAwake(false)
        pump(2.2); fire()
        check("a manual change in between is not flipped again", !keepAwakeOn)

        startSystemTimer(key, until: Date().addingTimeInterval(60)); pump(0.3)
        cancelSystemTimer(key); pump(0.3)
        check("cancel keeps the current state (on)", keepAwakeOn)
        check("cancel removes the timer", systemTimers[key] == nil)
        setKeepAwake(false)

        startSystemTimer(key, until: Date().addingTimeInterval(60)); pump(0.3)
        endSystemTimerNow(key); pump(0.3)
        check("end now flips it back at once", !keepAwakeOn)

        startSystemTimer(key, until: Date().addingTimeInterval(60)); pump(0.3)
        startSystemTimer(key, until: Date().addingTimeInterval(120)); pump(0.3)
        check("re-timing keeps it on and keeps the original restore state",
              keepAwakeOn && systemTimers[key]?.restoreOn == false)
        endSystemTimerNow(key); pump(0.3)

        if before != keepAwakeOn { setKeepAwake(before) }
        systemTimers = [:]
        lines.append("timer-probe: \(fails == 0 ? "all passed" : "\(fails) failed")")
        return lines.joined(separator: "\n")
    }

    // ── Kanban board server (pm2 "kanban", :5106) ───────────────────────────
    // This switch IS the on/off surface: no launchd, off after reboot by design.

    private func toggleKanban() {
        guard !kanbanBusy else { return }
        let stopping = kanbanUp == true
        kanbanBusy = true
        refreshPanel()
        dlog("kanban: \(stopping ? "stop" : "start")")
        // zsh -lc so pm2 resolves from the login PATH (GUI apps don't get it).
        let cmd = stopping ? "pm2 stop kanban"
            : "pm2 start kanban 2>/dev/null || pm2 start bun --name kanban -- \"\(Integrations.kanbanServer)\" --port 5106"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", cmd]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.kanbanBusy = false
                self?.refreshSnapshot()
            }
        }
        do { try task.run() } catch {
            derr("kanban toggle failed: \(fmtErr(error))")
            kanbanBusy = false
            refreshSnapshot()
        }
    }
}
