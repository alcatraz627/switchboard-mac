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
        var buttons: [RowButton] = []
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
        var devServers: [[String: Any]] = []
        var models: [String: Any] = [:]
        var remote: [String: Any] = [:]
        var git: [String: Any] = [:]
        var drives: [[String: Any]] = []
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
            s.drives = pyList("drives.py")
            let dev = Services.shell("/usr/bin/env", ["python3", AppPaths.lib("devservers.py"), "list"], timeout: 20)
            s.devServers = ((try? JSONSerialization.jsonObject(with: Data(dev.utf8)) as? [String: Any])?["servers"]
                as? [[String: Any]]) ?? []
            let models = Services.shell("/usr/bin/env", ["python3", AppPaths.lib("models.py"), "list"], timeout: 15)
            s.models = (try? JSONSerialization.jsonObject(with: Data(models.utf8)) as? [String: Any]) ?? [:]
            let g = Services.shell("/usr/bin/env", ["python3", AppPaths.lib("gitscan.py"), "list"], timeout: 90)
            s.git = (try? JSONSerialization.jsonObject(with: Data(g.utf8)) as? [String: Any]) ?? [:]
            if Integrations.csync {
                let r = Services.shell("/usr/bin/env", ["python3", AppPaths.lib("remote.py"), "list"], timeout: 70)
                s.remote = (try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any]) ?? [:]
            }
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
                              enabled: false, tip: "The cross-session message broker. Read-only here: it runs under launchd.",
                              buttons: [RowButton(label: "Copy", kind: .copy("claude-ipc -i"),
                                                  help: "Copy claude-ipc -i, the broker's interactive view, to paste in a terminal")]))
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
                              tip: "The session warden. Click toggles YOUR pause. The yellow standing-down state is the usage gate; it clears itself when a window reopens.",
                              buttons: [
                                  RowButton(label: "Transcript", kind: .run({ [weak self] in
                                      guard let sid = Warden.currentSession() else {
                                          return "the warden has no current session yet"
                                      }
                                      // The hub renders the page; start it when it is off, as its own
                                      // Services switch would, rather than sending you there.
                                      if !Services.probeHTTP("http://127.0.0.1:5400/healthz") {
                                          guard let hub = Integrations.hubScript else { return "the session hub is not installed" }
                                          _ = Services.shell("/bin/bash", [hub, "restart"], timeout: 15)
                                          var up = false
                                          for _ in 0..<20 where !up {
                                              Thread.sleep(forTimeInterval: 0.4)
                                              up = Services.probeHTTP("http://127.0.0.1:5400/healthz")
                                          }
                                          self?.refreshSnapshot()
                                          guard up else { return "the session hub did not start" }
                                      }
                                      DispatchQueue.main.async { TranscriptWindow.show(sessionID: sid, title: "Warden transcript") }
                                      return nil
                                  }), help: "Read the warden's session. Starts the session hub if it is off.",
                                            icon: "text.bubble", doing: "open the warden's transcript"),
                                  RowButton(label: "Copy", kind: .copy("claude-warden open"),
                                            help: "Copy claude-warden open: it opens a fork of the warden's session, so the warden itself and its beats are untouched"),
                              ]))
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
            self.policyController?.store.remoteGroups = self.panelRemoteGroups()
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
            row.buttons = r.buttons
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
        let dev = devServerRows()
        if !dev.isEmpty { out.append(SystemGroup(title: "Dev servers", rows: dev)) }
        let code = gitRows()
        if !code.isEmpty { out.append(SystemGroup(title: "Repos", rows: code)) }
        let drives = driveRows()
        if !drives.isEmpty { out.append(SystemGroup(title: "Drives", rows: drives)) }
        let models = modelRows()
        if !models.isEmpty { out.append(SystemGroup(title: "Local models", rows: models)) }
        let schedules = scheduleRows()
        if !schedules.isEmpty { out.append(SystemGroup(title: "Schedules", rows: schedules)) }
        out.append(SystemGroup(title: "Session", rows: sessionRows().map(convert) + [wakeOnLANRow()]))
        return out
    }

    /// The Machine tab as text, for checking the rows without a screen.
    func dumpSwitchboard() -> String {
        let groups = panelSystemGroupsFresh() + panelRemoteGroups().map { SystemGroup(title: "Remote · " + $0.title, rows: $0.rows) }
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
                out.append(String(format: "  %-20@ %-6@ %-28@ %@%@%@", r.label as NSString, badge as NSString,
                                  r.note as NSString, affordance as NSString, (r.enabled ? "" : " disabled") as NSString,
                                  r.buttons.map { "  [\($0.label)]" }.joined() as NSString))
                if let link = r.link { out.append("      link: \(link)") }
                for c in r.children {
                    let cb: String
                    switch c.state {
                    case .on: cb = "[on]"; case .off: cb = "(off)"
                    case .count(let n, _): cb = "[\(n)]"; case .ok: cb = "(ok)"
                    }
                    out.append(String(format: "      · %-26@ %-6@ %@%@", c.label as NSString, cb as NSString,
                                      c.note as NSString,
                                      ((c.buttonLabel.map { "  [\($0)]" } ?? "") + c.buttons.map { "  [\($0.label)]" }.joined()) as NSString))
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

    // ── Dev servers: the port ledger ─────────────────────────────────────────

    /// Local services (tier 2), your pinned ports (tier 1), and one-off demos
    /// (tier 3), each opening to its ports. See features/dev-servers.md.
    private func devServerRows() -> [SystemRow] {
        let all = sbSnapshot.devServers
        guard !all.isEmpty else { return [] }
        let script = AppPaths.lib("devservers.py")
        func tier(_ n: Int) -> [[String: Any]] { all.filter { ($0["tier"] as? Int) == n } }
        func live(_ s: [String: Any]) -> Bool { s["live"] as? Bool ?? false }
        let act: (String, String) -> () -> String? = { [weak self] verb, name in {
            let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script, verb, name], timeout: 20))
            self?.refreshSnapshot()
            return err
        } }
        func serverRow(_ s: [String: Any]) -> SystemRow {
            let port = s["port"] as? Int ?? 0, name = s["name"] as? String ?? "?"
            let pm2 = s["pm2"] as? String, on = live(s)
            let how = pm2 == "online" ? "pm2" : on ? (pm2 == nil ? "running" : "running outside pm2")
                : pm2 != nil ? "pm2, \(pm2!)" : "not running"
            var r = SystemRow(label: name, state: on ? .on(menuGreen) : .off, note: ":\(port) · \(how)",
                              tip: (s["note"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Claimed in the port ledger",
                              link: on ? "http://localhost:\(port)" : nil)
            r.key = "dev-\(port)"
            let owner = s["launchd"] as? String
            if pm2 == "online" {
                r.buttons = [RowButton(label: "Stop", kind: .run(act("stop", name)), help: "pm2 stop \(name)")]
            } else if pm2 != nil && !on {
                r.buttons = [RowButton(label: "Start", kind: .run(act("start", name)), help: "pm2 start \(name)")]
            } else if on, let owner = owner {
                // Killing a launchd job's server only makes launchd start it again.
                r.buttons = [RowButton(label: "Disable", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", AppPaths.lib("jobs.py"), "disable", owner], timeout: 20))
                    self?.refreshSnapshot()
                    return err
                }), help: "Stop it and keep it off: launchd runs it as \(owner)", doing: "disable \(owner)",
                   confirm: "Stop \(name) and keep it off? launchd runs it as \(owner), so it would come back after a kill. Enable it again under Schedules.")]
            } else if on {
                r.buttons = [RowButton(label: "Kill", kind: .run(act("kill", "\(port)")),
                                       help: "Stop the process listening on :\(port)", doing: "stop \(name)",
                                       confirm: "Stop \(name) on :\(port)? Nothing restarts it.")]
            }
            return r
        }
        var rows: [SystemRow] = []

        let services = tier(2)
        if !services.isEmpty {
            let up = services.filter(live)
            var r = SystemRow(label: "Local services", state: up.isEmpty ? .off : .count(up.count, menuGreen),
                              note: "\(up.count) of \(services.count) running",
                              tip: "Tier 2: persistent local services on 51xx, most under pm2. Click to open.")
            r.key = "dev-services"
            // Running ones first, so the few that matter are not buried under idle claims.
            r.children = (up + services.filter { !live($0) }).map(serverRow)
            rows.append(r)
        }

        let pins = tier(1)
        if !pins.isEmpty {
            let up = pins.filter(live)
            var r = SystemRow(label: "Pinned ports", state: up.isEmpty ? .off : .count(up.count, menuGreen),
                              note: pins.compactMap { ($0["port"] as? Int).map(String.init) }.joined(separator: ", ")
                                  + " · \(up.count) in use",
                              tip: "Tier 1: your own ports. Agents never take them. Read-only here.")
            r.key = "dev-pins"
            r.children = pins.map(serverRow)
            rows.append(r)
        }

        let oneOffs = tier(3)
        if !oneOffs.isEmpty {
            let up = oneOffs.filter(live)
            let expired = oneOffs.filter { $0["expired"] as? Bool ?? false }
            let expiredLive = expired.filter(live).compactMap { s -> String? in
                guard let n = s["name"] as? String, let p = s["port"] as? Int else { return nil }
                return "\(n) (:\(p))"
            }
            var r = SystemRow(label: "One-offs", state: up.isEmpty ? .off : .count(up.count, expiredLive.isEmpty ? menuGreen : menuYellow),
                              note: "\(up.count) running · \(expired.count) expired"
                                  + (expiredLive.isEmpty ? "" : ", \(expiredLive.count) still running"),
                              tip: "Tier 3: demos and previews on 62xx with a time limit. Reap stops the expired ones and records how to revive each.")
            r.key = "dev-oneoffs"
            r.children = up.map(serverRow)
            if !expired.isEmpty {
                r.buttons = [RowButton(label: "Reap", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script, "reap"], timeout: 40))
                    self?.refreshSnapshot()
                    return err
                }), help: "ports.sh reap: stop the expired one-offs and free their ports. Each can be brought back with ports.sh revive.",
                   confirm: "Reap \(expired.count) expired one-offs?"
                       + (expiredLive.isEmpty ? "" : " This stops \(expiredLive.joined(separator: ", ")), which is still running.")
                       + " Each can be revived with ports.sh revive.")]
            }
            rows.append(r)
        }

        var policy = SystemRow(label: "Port policy", state: .ok, note: "which ports agents may use",
                               tip: "features/dev-servers.md: the three tiers and how ports are claimed.",
                               link: "file://" + SwitchboardPaths.gccRoot + "/features/dev-servers.md")
        policy.showsBadge = false
        rows.append(policy)
        return rows
    }

    // ── Local models: the lm suite ───────────────────────────────────────────

    /// What the local models hold in memory, and the watchdog that protects the
    /// rest of the Mac from them.
    private func modelRows() -> [SystemRow] {
        let m = sbSnapshot.models
        guard m["suite"] as? Bool == true else { return [] }
        let script = AppPaths.lib("models.py")
        let run: ([String]) -> () -> String? = { [weak self] args in {
            let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script] + args, timeout: 130))
            self?.refreshSnapshot()
            return err
        } }
        var rows: [SystemRow] = []

        let up = m["ollama"] as? Bool ?? false
        let resident = m["resident"] as? [[String: Any]] ?? []
        let gb = resident.reduce(0.0) { $0 + ($1["gb"] as? Double ?? 0) }
        var ollama = SystemRow(label: "Ollama", state: !up ? .off : resident.isEmpty ? .ok : .count(resident.count, menuTeal),
                               note: !up ? "not running" : resident.isEmpty ? "no models loaded"
                                   : "\(resident.count) loaded · \(String(format: "%.1f", gb)) GB",
                               tip: "Models Ollama holds in memory, and how long each stays. Click to open.")
        ollama.key = "models-ollama"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ollama.children = resident.map { r in
            let name = r["name"] as? String ?? "?"
            let until = (r["until"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            // Ollama reports a pinned-forever model as expiring in the year 2318.
            let stay = until.map { $0.timeIntervalSinceNow > 86400 * 365 ? "stays loaded" : "unloads in \(countdownText(to: $0, now: Date()))" } ?? ""
            var c = SystemRow(label: name, state: .on(menuTeal),
                              note: "\(r["gb"] as? Double ?? 0) GB" + (stay.isEmpty ? "" : " · \(stay)"),
                              tip: "Resident in Ollama")
            c.key = "model-" + name
            c.buttons = [RowButton(label: "Unload", kind: .run(run(["unload", name])), help: "Free its memory now")]
            return c
        }
        if up, let warm = m["warm_model"] as? String {
            let on = m["warm"] as? Bool ?? false
            // A button, not a switch: loading takes longer than a switch waits
            // for confirmation, and the button waits for the real answer.
            var w = SystemRow(label: "Warm companion", state: on ? .on(menuGreen) : .off,
                              note: on ? "\(warm) loaded" : "\(warm), loads on first use",
                              tip: "lm's small default model, kept loaded so local calls answer at once. Same as warm on / warm off.")
            w.key = "models-warm"
            w.buttons = [RowButton(label: on ? "Unload" : "Load", kind: .run(run(["warm", on ? "off" : "on"])),
                                   help: on ? "warm off" : "warm on: load it and keep it loaded")]
            ollama.children.append(w)
        }
        rows.append(ollama)

        let pressure = m["pressure"] as? String ?? "unknown"
        var p = SystemRow(label: "Memory pressure",
                          state: pressure == "normal" ? .ok : .on(pressure == "warn" ? menuYellow : menuRed),
                          note: pressure, tip: "macOS's own memory pressure level. At critical it starts killing apps.")
        p.key = "models-pressure"
        rows.append(p)

        let guardOn = m["guard"] as? Bool ?? false
        var g = SystemRow(label: "mem-guard", state: guardOn ? .on(menuGreen) : .off,
                          note: guardOn ? "watching" : "off",
                          tip: "Stops the largest model before macOS runs out of memory and kills other apps. Runs up to 2 hours per start.",
                          action: {
                              DispatchQueue.global(qos: .userInitiated).async { _ = run(["guard", guardOn ? "off" : "on"])() }
                          })
        g.key = "models-guard"
        rows.append(g)

        let mlx = m["mlx"] as? [[String: Any]] ?? []
        if !mlx.isEmpty {
            var j = SystemRow(label: "mlx jobs", state: .count(mlx.count, menuTeal),
                              note: mlx.compactMap { $0["what"] as? String }.joined(separator: ", "),
                              tip: "Image and vision jobs running outside Ollama (see, imagine).")
            j.key = "models-mlx"
            rows.append(j)
        }
        return rows
    }

    // ── Drives: external disks and disk images ───────────────────────────────

    /// One row per attached drive, with its format and free space. The group
    /// is absent when nothing is attached.
    private func driveRows() -> [SystemRow] {
        let script = AppPaths.lib("drives.py")
        return sbSnapshot.drives.map { d in
            let name = d["name"] as? String ?? "?", mount = d["mount"] as? String ?? ""
            let disk = d["disk"] as? String ?? ""
            let total = d["total_gb"] as? Double ?? 0, free = d["free_gb"] as? Double ?? 0
            let kind = (d["image"] as? Bool ?? false) ? "disk image" : (d["protocol"] as? String ?? "external")
            var r = SystemRow(label: name, state: .on(menuTeal),
                              // Free space means nothing on a read-only volume (an installer image).
                              note: "\(kind) · \(d["format"] as? String ?? "?") · "
                                  + ((d["writable"] as? Bool ?? true)
                                     ? String(format: "%.1f of %.1f GB free", free, total)
                                     : String(format: "%.1f GB · read-only", total)),
                              tip: "\(mount) · \(disk)")
            r.key = "drive-" + mount
            r.showsBadge = false
            r.buttons = [RowButton(label: "Finder", kind: .run({
                DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: mount)) }
                return nil
            }), help: "Open in Finder")]
            if d["ejectable"] as? Bool ?? true {
                r.buttons.append(RowButton(label: "Eject", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script, "eject", disk], timeout: 70))
                    self?.refreshSnapshot()
                    return err
                }), help: "Eject \(disk) and every volume on it", doing: "eject \(name)"))
            }
            r.buttons.append(RowButton(label: "Disk Utility", kind: .run({
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
                return nil
            }), help: "Open Disk Utility, for formatting and repair"))
            return r
        }
    }

    // ── Code: git repositories under ~/Code ──────────────────────────────────

    /// Repositories that need attention, folded by what needs doing: commits
    /// not pushed, changes not committed, and detached or prunable checkouts.
    private func gitRows() -> [SystemRow] {
        let g = sbSnapshot.git
        guard let repos = g["repos"] as? [[String: Any]] else { return [] }
        let script = AppPaths.lib("gitscan.py")
        let editor = ["/Applications/Zed.app", "/Applications/Visual Studio Code.app", "/Applications/Cursor.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
        func repoRow(_ r: [String: Any]) -> SystemRow {
            let path = r["path"] as? String ?? ""
            let ahead = r["ahead"] as? Int ?? 0, behind = r["behind"] as? Int ?? 0, dirty = r["dirty"] as? Int ?? 0
            let prunable = r["prunable"] as? Int ?? 0, stashes = r["stashes"] as? Int ?? 0
            let bits: [String?] = [
                (r["detached"] as? Bool ?? false) ? "detached" : r["branch"] as? String,
                ahead > 0 ? "\(ahead) unpushed" : nil,
                behind > 0 ? "\(behind) behind" : nil,
                dirty > 0 ? "\(dirty) changed" : nil,
                stashes > 0 ? "\(stashes) stashed" : nil,
                prunable > 0 ? "\(prunable) prunable worktree\(prunable == 1 ? "" : "s")" : nil,
                r["error"] as? String,
            ]
            var row = SystemRow(label: r["name"] as? String ?? path, state: .off,
                                note: bits.compactMap { $0 }.joined(separator: " · "), tip: path)
            row.key = "repo-" + path
            row.showsBadge = false
            row.buttons = [
                RowButton(label: "Finder", kind: .run({
                    DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    return nil
                }), help: "Open in Finder"),
                RowButton(label: "Terminal", kind: .run({
                    let out = Services.shell("/usr/bin/open", ["-na", "Ghostty.app", "--args", "--working-directory=\(path)"])
                    return out.isEmpty ? nil : out
                }), help: "Open a Ghostty window here"),
            ]
            if let editor = editor {
                row.buttons.append(RowButton(label: "Editor", kind: .run({
                    let out = Services.shell("/usr/bin/open", ["-a", editor, path])
                    return out.isEmpty ? nil : out
                }), help: "Open in \((editor as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))"))
            }
            row.buttons.append(RowButton(label: "Fetch", kind: .run({ [weak self] in
                let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script, "fetch", path], timeout: 70))
                self?.refreshSnapshot()
                return err
            }), help: "git fetch: see what the remote has, without changing your files", doing: "fetch"))
            if prunable > 0 {
                row.buttons.append(RowButton(label: "Prune", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script, "prune", path], timeout: 70))
                    self?.refreshSnapshot()
                    return err
                }), help: "git worktree prune: forget worktrees whose folders are gone", doing: "prune worktrees",
                   confirm: "Prune \(prunable) worktree record\(prunable == 1 ? "" : "s") in \(row.label)? Only records whose folders no longer exist are removed."))
            }
            return row
        }
        func bucket(_ label: String, _ items: [[String: Any]], tint: NSColor, tip: String) -> SystemRow? {
            guard !items.isEmpty else { return nil }
            var b = SystemRow(label: label, state: .count(items.count, tint),
                              note: items.prefix(3).compactMap { ($0["name"] as? String).map { ($0 as NSString).lastPathComponent } }
                                  .joined(separator: ", ") + (items.count > 3 ? " +\(items.count - 3)" : ""),
                              tip: tip)
            b.key = "git-" + label
            b.children = items.map(repoRow)
            return b
        }
        let unpushed = repos.filter { ($0["ahead"] as? Int ?? 0) > 0 }
        let changed = repos.filter { ($0["ahead"] as? Int ?? 0) == 0 && ($0["dirty"] as? Int ?? 0) > 0 }
        let other = repos.filter { ($0["ahead"] as? Int ?? 0) == 0 && ($0["dirty"] as? Int ?? 0) == 0 }
        var rows = [
            bucket("Unpushed commits", unpushed, tint: menuYellow, tip: "Commits on a branch that its own remote branch does not have yet."),
            bucket("Uncommitted changes", changed, tint: menuTeal, tip: "Files changed and not committed."),
            bucket("Worktrees to tidy", other, tint: menuTeal, tip: "Detached checkouts and worktree records whose folders are gone."),
        ].compactMap { $0 }
        let clean = g["clean"] as? Int ?? 0
        let scanned = (g["scanned_at"] as? Double).map { age(Date(timeIntervalSince1970: $0)) } ?? "not yet"
        var summary = SystemRow(label: "\(clean) clean", state: .ok, note: "~/Code, 3 levels deep · scanned \(scanned)",
                                tip: "Repositories with nothing to commit, push or tidy.")
        summary.key = "git-clean"
        summary.showsBadge = false
        rows.append(summary)
        return rows
    }

    /// The "…" menu on an online host: chat with its agent, read-only verbs in
    /// a terminal, keep-connected, and copyable lines for verbs that need more.
    private func hostMenu(_ name: String, script: String,
                          act: @escaping ([String]) -> () -> String?) -> [(title: String, run: (() -> String?)?)] {
        func copy(_ text: String) -> () -> String? {
            { DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }; return nil }
        }
        let chatCommand: () -> String? = {
            let out = Services.shell("/usr/bin/env", ["python3", script, "chatcmd", name])
            guard let d = out.data(using: .utf8),
                  let cmd = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["command"] as? String
            else { return "could not build the chat command" }
            return copy(cmd)()
        }
        return [
            ("Chat with csync-assist", act(["chat", name])),
            ("Copy the chat command", chatCommand),
            ("", nil),
            ("Info in a terminal", act(["term", name, "info"])),
            ("Logs in a terminal", act(["term", name, "logs"])),
            ("Recipes in a terminal", act(["term", name, "recipes"])),
            ("", nil),
            ("Keep connected across reboots", act(["persist", name, "on"])),
            ("Stop keeping connected", act(["persist", name, "off"])),
            ("", nil),
            ("Copy: run a command", copy("csync run \(name) -- ")),
            ("Copy: send a file", copy("csync push \(name) ")),
            ("Copy: fetch a file", copy("csync pull \(name) ")),
            ("Copy: show a message on it", copy("csync say \(name) \"\"")),
            ("Copy: open an app on it", copy("csync open \(name) ")),
        ]
    }

    // ── Remote: machines driven through csync ────────────────────────────────

    /// The Remote tab: csync's console health, then each host with the actions
    /// its state allows, then a row to invite a new one.
    func panelRemoteGroups() -> [SystemGroup] {
        let m = sbSnapshot.remote
        guard m["installed"] as? Bool == true else { return [] }
        let script = AppPaths.lib("remote.py")
        let act: ([String]) -> () -> String? = { [weak self] args in {
            let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script] + args, timeout: 130))
            self?.refreshSnapshot()
            return err
        } }
        var groups: [SystemGroup] = []

        let checks = m["checks"] as? [[String: Any]] ?? []
        if !checks.isEmpty {
            let failing = checks.filter { !($0["ok"] as? Bool ?? false) }
            var health = SystemRow(label: "Console health",
                                   state: failing.isEmpty ? .ok : .count(failing.count, menuRed),
                                   note: failing.isEmpty ? "relay, Tailscale and Funnel all good"
                                       : failing.compactMap { $0["check"] as? String }.joined(separator: ", ") + " failing",
                                   tip: "csync doctor: what this Mac needs to reach the other machines. Click to open.")
            health.key = "remote-health"
            // Failing checks first; they are the only ones worth reading.
            health.children = (failing + checks.filter { $0["ok"] as? Bool ?? false }).map { c in
                let ok = c["ok"] as? Bool ?? false
                var r = SystemRow(label: c["check"] as? String ?? "?", state: ok ? .ok : .off,
                                  note: (ok ? "" : "failing · ") + (c["detail"] as? String ?? ""),
                                  tip: (c["fix"] as? String).map { "Fix: \($0)" } ?? "")
                r.key = "check-" + r.label
                return r
            }
            if !failing.isEmpty {
                health.buttons = [RowButton(label: "Fix", kind: .run(act(["fix"])),
                                            help: "csync doctor --fix", doing: "fix the console")]
            }
            groups.append(SystemGroup(title: "Console", rows: [health]))
        }

        let hosts = m["hosts"] as? [[String: Any]] ?? []
        var rows: [SystemRow] = hosts.map { h in
            let name = h["name"] as? String ?? "?", status = h["status"] as? String ?? "?"
            let os = (h["os"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let seen = (h["last_seen"] as? Double).map { age(Date(timeIntervalSince1970: $0)) }
            let expires = (h["expires"] as? Double).map { countdownText(to: Date(timeIntervalSince1970: $0), now: Date()) }
            let note: String
            switch status {
            case "online": note = [os, "online"].compactMap { $0 }.joined(separator: " · ")
            case "invited": note = "invited, waiting for the paste" + (expires.map { " · expires in \($0)" } ?? "")
            case "expired": note = "invite expired"
            default: note = [os, "offline" + (seen.map { ", last seen \($0)" } ?? "")].compactMap { $0 }.joined(separator: " · ")
            }
            var r = SystemRow(label: name, state: status == "online" ? .on(menuGreen) : .off, note: note,
                              tip: [h["user"] as? String, (h["route"] as? String).map { "route \($0)" }].compactMap { $0 }.joined(separator: " · "))
            r.key = "host-" + name
            if status == "online" {
                r.buttons = [
                    RowButton(label: "Screenshot", kind: .run(act(["shot", name])),
                              help: "Take a screenshot of \(name) and open it", doing: "screenshot \(name)"),
                    RowButton(label: "Shell", kind: .run(act(["shell", name])),
                              help: "Open a Ghostty window with a shell on \(name)", doing: "open a shell on \(name)"),
                    RowButton(label: "More", kind: .menu(hostMenu(name, script: script, act: act)),
                              help: "Chat with its agent, and the other csync commands"),
                    RowButton(label: "Teardown", kind: .run(act(["teardown", name])),
                              help: "End the session and clean csync off \(name)", doing: "tear down \(name)",
                              confirm: "Tear down \(name)? It ends the session and removes csync from that machine. Reconnecting needs a new invite."),
                ]
            } else {
                r.buttons = [RowButton(label: "Forget", kind: .run(act(["forget", name])),
                                       help: status == "invited" ? "Cancel the invite" : "Drop it from the list",
                                       doing: "forget \(name)",
                                       confirm: status == "invited" ? "Cancel the invite for \(name)?" : nil)]
            }
            return r
        }
        var invite = SystemRow(label: "Invite a machine", state: .off, note: "copies the line to paste on it",
                               tip: "csync invite: mints the one line to paste on the other machine's terminal.")
        invite.key = "host-invite"
        invite.showsBadge = false
        invite.buttons = [RowButton(label: "Invite", kind: .ask(placeholder: "A name for it, like studio-mac") { [weak self] name in
            let out = Services.shell("/usr/bin/env", ["python3", script, "invite", name], timeout: 70)
            if let err = Self.helperError(out) { return err }
            guard let d = out.data(using: .utf8),
                  let paste = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["paste"] as? String
            else { return "csync gave no line to paste" }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paste, forType: .string)
            }
            self?.refreshSnapshot()
            return nil
        }, help: "Name the machine; the paste line lands on your clipboard", doing: "invite that machine")]
        rows.append(invite)
        groups.append(SystemGroup(title: "Hosts", rows: rows))
        return groups
    }

    // ── Schedules: launchd jobs ──────────────────────────────────────────────

    private func scheduleRows() -> [SystemRow] {
        let jobs = sbSnapshot.jobs
        guard !jobs.isEmpty else { return [] }
        // Always-on agents are services, not schedules: one row that opens to
        // list them. Failing scheduled jobs also earn a top row of their own.
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
                              tip: "Agents launchd keeps alive. Click to open.")
            r.key = "always-on-agents"
            r.children = always.map(jobRow)
            rows.append(r)
        }
        if !healthy.isEmpty {
            var r = SystemRow(label: "Scheduled jobs", state: .count(healthy.count, menuGreen),
                              note: "last runs ok", tip: "launchd jobs that run on a clock. Click to open.")
            r.key = "scheduled-jobs"
            r.children = healthy.map(jobRow)
            rows.append(r)
        }
        for j in timed where j["failing"] as? Bool ?? false {
            var r = jobRow(j)
            r.key = "failing-" + (j["label"] as? String ?? "")
            rows.append(r)
        }
        return rows
    }

    /// One launchd job as a row: its state, when it runs, and Start or Stop
    /// plus Open (its log, or the plist in Finder when it keeps no log).
    private func jobRow(_ j: [String: Any]) -> SystemRow {
        let script = AppPaths.lib("jobs.py")
        let label = j["label"] as? String ?? ""
        let schedule = j["schedule"] as? String ?? ""
        let running = j["running"] as? Bool ?? false
        let loaded = j["loaded"] as? Bool ?? false
        let exit = (j["last_exit"] as? NSNumber)?.intValue
        let failing = j["failing"] as? Bool ?? false
        let state: SystemRow.State = running ? .on(menuGreen) : failing ? .count(exit ?? 1, menuRed) : .off
        let status = (j["disabled"] as? Bool ?? false) ? "disabled" : running ? "running" : !loaded ? "not loaded" : failing ? "last run failed (exit \(exit ?? 1))"
            : exit == 0 ? "last run ok" : "idle"
        // This app's own agent gets no Start or Stop: Stop would quit the
        // panel mid-click, Start would launch a second copy.
        let isSelf = label == "io.github.alcatraz627.switchboard"
        let always = schedule == "always running"
        var r = SystemRow(label: (j["name"] as? String ?? "?").capitalized, state: state,
                          note: (always ? status : "\(schedule) · \(status)") + (isSelf ? " · this app" : ""),
                          tip: label + ((j["program"] as? String).map { " · runs \($0)" } ?? ""))
        // Two plists can carry one Label (pm2's user and root agents are both com.PM2).
        r.key = j["plist"] as? String ?? label
        let act: (String) -> () -> String? = { [weak self] verb in {
            let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", script, verb, label], timeout: 15))
            self?.refreshSnapshot()
            return err
        } }
        if isSelf {
            // Open only.
        } else if running {
            r.buttons.append(RowButton(label: "Stop", kind: .run(act("stop")),
                                       help: always ? "Unload it, so launchd stops restarting it. Start loads it again."
                                                    : "Stop this run. The next scheduled run still happens.",
                                       confirm: always ? "Stop \(r.label)? launchd will not restart it until you press Start." : nil))
        } else {
            r.buttons.append(RowButton(label: "Start", kind: .run(act("start")),
                                       help: loaded ? "Run it now" : "Load it into launchd and run it"))
        }
        if !isSelf {
            if j["disabled"] as? Bool ?? false {
                r.buttons = [RowButton(label: "Enable", kind: .run(act("enable")),
                                       help: "Let it run again, at login and on its schedule")]
            } else {
                r.buttons.append(RowButton(label: "Disable", kind: .run(act("disable")),
                                           help: "Stop it and keep it off, even after a restart, until you enable it",
                                           confirm: "Disable \(r.label)? It stops now and stays off after restarts until you press Enable."))
            }
        }
        let log = j["log"] as? String, plist = j["plist"] as? String
        if log != nil || plist != nil {
            r.buttons.append(RowButton(label: "Open", kind: .run({
                DispatchQueue.main.async {
                    if let log = log { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                    else if let plist = plist { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]) }
                }
                return nil
            }), help: log != nil ? "Open its log" : "Show its plist in Finder (it keeps no log)"))
        }
        return r
    }

    /// What a lib helper's `{"ok": …, "error": …}` answer means for a button:
    /// nil when it worked, otherwise the reason in the helper's words.
    static func helperError(_ out: String) -> String? {
        guard let d = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            let raw = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "no answer" : raw
        }
        return (obj["ok"] as? Bool ?? false) ? nil : (obj["error"] as? String ?? "refused")
    }

    // ── Wake-on-LAN ──────────────────────────────────────────────────────────

    private func wakeOnLANRow() -> SystemRow {
        let targets = sbSnapshot.wolTargets
        let wol = AppPaths.lib("wol.py")
        var row = SystemRow(
            label: "Wake a device",
            state: targets.isEmpty ? .off : .count(targets.count, menuTeal),
            note: targets.isEmpty ? "no saved devices" : targets.compactMap { $0["name"] as? String }.joined(separator: ", "),
            tip: "Send a wake-on-LAN packet to a saved machine on the home network. Click to open.")
        row.key = "wake-a-device"
        row.children = targets.map { t in
            let name = t["name"] as? String ?? "?", mac = t["mac"] as? String ?? ""
            let bcast = t["broadcast"] as? String ?? "255.255.255.255"
            var r = SystemRow(label: name, state: .off, note: mac, tip: "Broadcast to \(bcast)")
            r.key = "wol-" + mac
            r.showsBadge = false
            r.buttons = [
                RowButton(label: "Wake", kind: .run({
                    let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", wol, "wake", mac, bcast]))
                    dlog("wol: \(name) \(err ?? "sent")")
                    return err
                }), help: "Send the magic packet. A sleeping machine takes a few seconds to answer."),
                RowButton(label: "Forget", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.shell("/usr/bin/env", ["python3", wol, "remove", mac]))
                    self?.refreshSnapshot()
                    return err
                }), help: "Remove it from the saved devices"),
            ]
            return r
        }
        var add = SystemRow(label: "Add a device", state: .off, note: "name and MAC address",
                            tip: "Save a machine to wake. It must have wake-on-LAN turned on.")
        add.key = "wol-add"
        add.showsBadge = false
        add.buttons = [RowButton(label: "Add…", kind: .run({ [weak self] in
            DispatchQueue.main.async { self?.addWakeTarget(wol) }
            return nil
        }))]
        row.children.append(add)
        return row
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
