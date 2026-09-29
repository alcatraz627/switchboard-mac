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
    /// Timed flips that did not land, by switch, shown on the switch's row
    /// until the switch is flipped or timed again.
    var timerFailures: [String: String] = [:]
    /// Why the last kanban start or stop failed, shown on its row until the next try.
    private var kanbanError: String?

    // ── Lifecycle ────────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ note: Notification) {
        dlog("─── switchboard starting (pid \(getpid()), lib \(AppPaths.libDir)) ───")
        PreferenceMigration.run()
        EditMenu.install()
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
        var needs: [NeedItem] = []
        /// Helpers whose last run failed, by script name, with the reason in
        /// words. Their group still shows its previous value, marked stale.
        var probeFailures: [String: String] = [:]
        /// When each helper last answered, to date a stale value.
        var probeReadAt: [String: Date] = [:]
        /// Set when the dev server list came back but pm2 did not answer.
        var pm2Error: String? = nil
    }

    /// How a helper-backed group should read: nil when its last probe worked.
    func probeStatus(_ name: String) -> ReadingState? {
        guard let why = sbSnapshot.probeFailures[name] else { return nil }
        return sbSnapshot.probeReadAt[name].map { .stale($0, why) } ?? .failed(why)
    }

    /// Refresh the slow half off the main thread. The panel shows whatever
    /// the last snapshot held and never waits on a probe. One refresh runs at a
    /// time: a request while one is running queues a single rerun, since
    /// opening the panel asks from several tabs at once.
    func refreshSnapshot(completion: (() -> Void)? = nil) {
        // Row actions call this from background queues; the running flag lives on main.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshSnapshot(completion: completion) }
            return
        }
        if let c = completion { snapshotWaiters.append(c) }
        guard !snapshotRunning else { snapshotAgain = true; return }
        snapshotRunning = true
        let previous = sbSnapshot
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var s = SBSnapshot()
            // The helpers are separate processes, so they run side by side; a
            // snapshot takes as long as its slowest probe, not all of them.
            let group = DispatchGroup()
            let lock = NSLock()
            func probe(_ name: String, _ args: [String], timeout: TimeInterval, _ apply: @escaping (Any) -> Void) {
                // A section hidden in Settings is never read, so it costs nothing.
                let owner: [String: String] = ["jobs.py": "Schedules", "drives.py": "Drives", "devservers.py": "Dev servers",
                                               "models.py": "Local models", "gitscan.py": "Repos", "wol.py": "Session"]
                if let section = owner[name], Visibility.groupHidden(section) { return }
                if name == "remote.py", Visibility.tabHidden("remote") { return }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    let r = Services.run("/usr/bin/env", ["python3", AppPaths.lib(name)] + args, timeout: timeout)
                    // A probe that failed keeps its last value instead of emptying its group.
                    guard let v = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) else {
                        let why = r.failure ?? "\(name) gave no answer"
                        dwarn("probe failed, keeping the last value: \(why)")
                        lock.lock(); s.probeFailures[name] = why; lock.unlock()
                        return
                    }
                    lock.lock(); apply(v); s.probeReadAt[name] = Date(); lock.unlock()
                }
            }
            s.jobs = previous.jobs; s.wolTargets = previous.wolTargets; s.drives = previous.drives
            s.devServers = previous.devServers; s.models = previous.models; s.git = previous.git; s.remote = previous.remote
            s.probeReadAt = previous.probeReadAt
            probe("jobs.py", ["list"], timeout: 8) { if let v = $0 as? [[String: Any]] { s.jobs = v } }
            probe("wol.py", ["list"], timeout: 8) { if let v = $0 as? [[String: Any]] { s.wolTargets = v } }
            probe("drives.py", ["list"], timeout: 30) { if let v = $0 as? [[String: Any]] { s.drives = v } }
            probe("devservers.py", ["list"], timeout: 50) {
                guard let d = $0 as? [String: Any], let v = d["servers"] as? [[String: Any]] else { return }
                s.devServers = v
                s.pm2Error = d["pm2_error"] as? String
            }
            probe("models.py", ["list"], timeout: 25) { if let v = $0 as? [String: Any] { s.models = v } }
            probe("gitscan.py", ["list"], timeout: 90) { if let v = $0 as? [String: Any] { s.git = v } }
            if Integrations.csync {
                probe("remote.py", ["list"], timeout: 70) { if let v = $0 as? [String: Any] { s.remote = v } }
            }
            if Integrations.guardHooks && !Visibility.groupHidden("Guards") {
                s.muted = Guards.muted()
                s.gates = Guards.all()
            }
            s.approvals = PushApprovals.armed(liveSessionIDs: LiveSessions.ids())
            s.needs = NeedsYou.items()
            if Integrations.claudeCode {
                for f in SettingsFlag.allCases { s.prompts[f] = Settings.bool(f) }
                s.connectorsOn = ContextSwitches.connectorsOn()
                s.browserToolsOn = ContextSwitches.browserToolsOn()
            }
            s.boardSync = BoardSync.enabled()
            // Services are several network and login-shell probes; hidden, none run.
            let servicesShown = !Visibility.groupHidden("Services")
            if servicesShown, Integrations.hubScript != nil {
                s.hubHost = Services.hubAdvertisedHost()
                s.hubLocal = Services.probeHTTP("http://127.0.0.1:5400/healthz")
                s.hubReachable = s.hubHost.map { Services.probeHTTP("http://\($0):5400/healthz") } ?? s.hubLocal
            }
            if servicesShown, Integrations.ipcBroker {
                s.brokerUp = Services.shell("/bin/zsh", ["-lc", "claude-ipc daemon status 2>/dev/null"]).contains("up")
            }
            if servicesShown {
                s.decisionPages = Services.pm2Status("decision-pages")
                s.wardenRunning = Warden.installed() ? Warden.running() : nil
            }
            if s.wardenRunning == true {
                s.wardenGated = Warden.gated()
                if let n = Int(PolicyCLI.run(["get", "ops.usage_gate_pct"]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)) { s.wardenGatePct = n }
            }
            let kanban = servicesShown && Integrations.kanban ? Services.probeHTTP("http://127.0.0.1:5106/api/boards") : nil
            s.awakeHolders = Self.sleepHolders()
            group.wait()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sbSnapshot = s
                if !self.kanbanBusy { self.kanbanUp = kanban }
                self.refreshPanel()
                let waiters = self.snapshotWaiters
                self.snapshotWaiters = []
                waiters.forEach { $0() }
                self.snapshotRunning = false
                if self.snapshotAgain {
                    self.snapshotAgain = false
                    self.refreshSnapshot()
                }
            }
        }
    }
    private var snapshotRunning = false
    private var snapshotAgain = false
    private var snapshotWaiters: [() -> Void] = []

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
                                      tip: "Switched off by ~/.claude/\(m.sentinel). Re-arm deletes that file; muting again stays a deliberate act in a shell.")
                    r.key = "gate-muted-" + g.name
                    r.buttons = [RowButton(label: "Re-arm", kind: .run({ [weak self] in
                        let ok = Guards.rearm(m)
                        self?.refreshSnapshot()
                        return ok ? nil : "~/.claude/\(m.sentinel) could not be removed"
                    }), help: "Re-arm: delete ~/.claude/\(m.sentinel)", doing: "re-arm it")]
                    return r
                case .snoozed(let z):
                    var r = SystemRow(label: g.name, state: .off,
                                      note: "snoozed" + (z.until.map { " until \(f.string(from: $0))" } ?? "")
                                          + (z.scope == "global" ? "" : " · \(z.scope)"),
                                      tip: z.reason.isEmpty ? "Snoozed through hook-snooze.sh." : z.reason)
                    r.key = "gate-snoozed-" + z.id
                    r.buttons = [RowButton(label: "Lift", kind: .run({ [weak self] in
                        let ok = HookSnoozes.lift(z)
                        self?.refreshSnapshot()
                        return ok ? nil : "the snooze is still in force after hook-snooze.sh lift"
                    }), help: "Lift the snooze now", doing: "lift it")]
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
        return rows
    }


    private func serviceRows() -> [SBRow] {
        let s = sbSnapshot
        var rows: [SBRow] = []

        if Integrations.kanban {
            let note = kanbanBusy ? "working…" : kanbanError.map { "couldn't switch: \($0)" }
                ?? (kanbanUp == nil ? "probing…" : kanbanUp! ? "serving :5106" : "not running")
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
                                      // A restart waits for the port; the 4 s default killed it midway.
                                      _ = Services.run("/bin/bash", [hub, up ? "stop" : "restart"], timeout: 15)
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
                                  // pm2 runs through a login shell: seconds, so never on main.
                                  DispatchQueue.global(qos: .userInitiated).async {
                                      Services.pm2(dp == "online" ? "stop" : "start", "decision-pages")
                                      self?.refreshSnapshot()
                                  }
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
                                  let on = !(self?.sbSnapshot.boardSync ?? false)
                                  DispatchQueue.global(qos: .userInitiated).async {
                                      BoardSync.set(on)
                                      self?.refreshSnapshot()
                                  }
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
            self.policyController?.store.setNeeds(self.sbSnapshot.needs) { [weak self] in self?.refreshSnapshot() }
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
            let failed = timerFailures[r.label]
            // A manual flip clears a timer failure: the owner has taken it from here.
            let onClick: (() -> Void)? = r.onClick.map { act in { [weak self] in self?.timerFailures[r.label] = nil; act() } }
            var row = SystemRow(label: r.label, state: state, note: failed.map { "⚠︎ " + $0 } ?? r.note, enabled: r.enabled,
                                tip: r.tip, link: r.link, action: onClick, menu: r.submenu)
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
        // A helper-backed group shows while it has rows or while its helper is
        // failing, so a broken read never looks like "nothing there".
        for (title, helper, rows) in [("Dev servers", "devservers.py", devServerRows()), ("Repos", "gitscan.py", gitRows()),
                                      ("Drives", "drives.py", driveRows()), ("Local models", "models.py", modelRows()),
                                      ("Schedules", "jobs.py", scheduleRows())] {
            var st = probeStatus(helper)
            if st == nil, helper == "devservers.py", let why = sbSnapshot.pm2Error {
                st = .stale(Date(), why + ", so pm2 states are unknown")
            }
            if !rows.isEmpty || st != nil { out.append(SystemGroup(title: title, rows: rows, status: st)) }
        }
        out.append(SystemGroup(title: "Session", rows: sessionRows().map(convert) + [wakeOnLANRow()]))
        return out.filter { !Visibility.groupHidden($0.title) }
    }

    /// The Machine tab as text, for checking the rows without a screen.
    func dumpSwitchboard() -> String {
        let groups = panelSystemGroupsFresh() + panelRemoteGroups().map { SystemGroup(title: "Remote · " + $0.title, rows: $0.rows) }
        var out = ["SWITCHBOARD DUMP"]
        for g in groups {
            out.append("\n\(g.title.uppercased())")
            switch g.status {
            case .stale(let d, let why)?: out.append("  status: stale, last read \(age(d)): \(why)")
            case .failed(let why)?: out.append("  status: failed: \(why)")
            default: break
            }
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
            let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script, verb, name], timeout: 20))
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
                    let err = Self.helperError(Services.run("/usr/bin/env", ["python3", AppPaths.lib("jobs.py"), "disable", owner], timeout: 20))
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
                    let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script, "reap"], timeout: 40))
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
            let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script] + args, timeout: 130))
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
                    let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script, "eject", disk], timeout: 70))
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
                RowButton(label: "Terminal", kind: .copy("cd '\(path.replacingOccurrences(of: "'", with: "'\\''"))'"),
                          help: "Copy a cd to this repository, to paste in your terminal"),
            ]
            if let editor = editor {
                row.buttons.append(RowButton(label: "Editor", kind: .run({
                    let out = Services.shell("/usr/bin/open", ["-a", editor, path])
                    return out.isEmpty ? nil : out
                }), help: "Open in \((editor as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))"))
            }
            row.buttons.append(RowButton(label: "Fetch", kind: .run({ [weak self] in
                let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script, "fetch", path], timeout: 70))
                self?.refreshSnapshot()
                return err
            }), help: "git fetch: see what the remote has, without changing your files", doing: "fetch"))
            if prunable > 0 {
                row.buttons.append(RowButton(label: "Prune", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script, "prune", path], timeout: 70))
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

    /// A csync command to paste in a terminal: full path, since csync is often
    /// not on the PATH, and marked as the owner's, since csync refuses writes
    /// it takes for an agent's.
    static func csyncLine(_ verb: String, _ host: String) -> String {
        let bin = Integrations.csyncPath.map { $0.contains(" ") ? "'\($0)'" : $0 } ?? "csync"
        return "CSYNC_ACTOR=human \(bin) \(verb) \(host)"
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
            ("Copy: chat with csync-assist", chatCommand),
            ("", nil),
            ("Copy: info", copy(Self.csyncLine("info", name))),
            ("Copy: logs", copy(Self.csyncLine("logs", name))),
            ("Copy: recipes", copy(Self.csyncLine("recipes", name))),
            ("", nil),
            ("Keep connected across reboots", act(["persist", name, "on"])),
            ("Stop keeping connected", act(["persist", name, "off"])),
            ("", nil),
            ("Copy: run a command", copy(Self.csyncLine("run", name) + " -- ")),
            ("Copy: send a file", copy(Self.csyncLine("push", name) + " ")),
            ("Copy: fetch a file", copy(Self.csyncLine("pull", name) + " ")),
            ("Copy: show a message on it", copy(Self.csyncLine("say", name) + " \"\"")),
            ("Copy: open an app on it", copy(Self.csyncLine("open", name) + " ")),
        ]
    }

    // ── Remote: machines driven through csync ────────────────────────────────

    /// The Remote tab: csync's console health, then each host with the actions
    /// its state allows, then a row to invite a new one.
    func panelRemoteGroups() -> [SystemGroup] {
        let m = sbSnapshot.remote
        let readStatus = probeStatus("remote.py")
        guard m["installed"] as? Bool == true else {
            return readStatus.map { [SystemGroup(title: "Console", rows: [], status: $0)] } ?? []
        }
        let script = AppPaths.lib("remote.py")
        let act: ([String]) -> () -> String? = { [weak self] args in {
            let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script] + args, timeout: 130))
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
                    RowButton(label: "Shell", kind: .copy(Self.csyncLine("sh", name)),
                              help: "Copy the command for a shell on \(name), to paste in your terminal"),
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
            let r = Services.run("/usr/bin/env", ["python3", script, "invite", name], timeout: 70)
            if let err = Self.helperError(r) { return err }
            guard let d = r.out.data(using: .utf8),
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
        if let st = readStatus { groups[0].status = st }
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
            let err = Self.helperError(Services.run("/usr/bin/env", ["python3", script, verb, label], timeout: 15))
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
    /// What went wrong with a helper call, in words, or nil when it answered ok.
    /// The helper's own error wins; otherwise the run's failure (could not
    /// start, timed out, crashed) says why there was no answer.
    static func helperError(_ r: ShellResult) -> String? {
        guard let d = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            if let why = r.failure { return why }
            let raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "\(r.name) gave no answer" : raw
        }
        return (obj["ok"] as? Bool ?? false) ? nil : plainError(obj["error"] as? String ?? "\(r.name) refused")
    }

    /// A tool's error in words a person reads: colour codes and table borders
    /// gone, known launchctl, pm2 and permission failures said plainly, and
    /// otherwise the first line that says something.
    static func plainError(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        let known: [(String, String)] = [
            (#"(?i)bootstrap failed: 5|input/output error"#, "launchd would not load it; it may be loaded already, or its plist is broken"),
            (#"(?i)bootstrap failed: 37|already (loaded|bootstrapped)"#, "it is loaded already"),
            (#"(?i)could not find service|no such process|service is disabled"#, "launchd has no running job by that name right now"),
            (#"(?i)operation not permitted|permission denied|EPERM"#, "macOS did not allow it (permission denied)"),
            (#"(?i)\[PM2\]\[ERROR\] Process or Namespace (\S+) not found"#, "pm2 has no process named $1"),
            (#"(?i)command not found: (\S+)"#, "$1 is not installed or not on the PATH"),
            (#"(?i)(\S+): command not found"#, "$1 is not installed or not on the PATH"),
        ]
        for (pattern, plain) in known {
            // Rewrite only the matched text, so a capture ($1) carries the name through.
            if let r = text.range(of: pattern, options: .regularExpression) {
                return String(text[r]).replacingOccurrences(of: pattern, with: plain, options: .regularExpression)
            }
        }
        let boxChars = CharacterSet(charactersIn: "│┌┐└┘├┤┬┴┼─═║╔╗╚╝")
        // A table (pm2 prints one) carries no reason, so its lines are skipped whole.
        let line = text.components(separatedBy: "\n")
            .filter { $0.rangeOfCharacter(from: boxChars) == nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("[PM2] ") && $0.rangeOfCharacter(from: .letters) != nil }
        guard let l = line else { return "it failed without saying why" }
        return l.count > 160 ? String(l.prefix(157)) + "…" : l
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
                    let err = Self.helperError(Services.run("/usr/bin/env", ["python3", wol, "wake", mac, bcast]))
                    dlog("wol: \(name) \(err ?? "sent")")
                    return err
                }), help: "Send the magic packet. A sleeping machine takes a few seconds to answer."),
                RowButton(label: "Forget", kind: .run({ [weak self] in
                    let err = Self.helperError(Services.run("/usr/bin/env", ["python3", wol, "remove", mac]))
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
        let (n, m) = (name.stringValue, mac.stringValue)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A timeout or crash is a failure too, not a quiet save.
            let err = Self.helperError(Services.run("/usr/bin/env", ["python3", wol, "add", n, m], timeout: 8))
            DispatchQueue.main.async {
                if let err = err {
                    let e = NSAlert(); e.messageText = "\(n.isEmpty ? "The device" : n) was not saved"; e.informativeText = err
                    NSApp.activate(ignoringOtherApps: true)
                    e.runModal()
                }
                self?.refreshSnapshot()
            }
        }
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
        timerFailures[key] = nil
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
                    self.verifyTimedFlip(key, wantOn: t.restoreOn)
                } else {
                    dlog("timer: \(key) due, already \(t.restoreOn ? "on" : "off")")
                }
            }
            self.refreshSnapshot()
        }
    }

    /// Some switches take seconds (pm2, a login shell), so the check waits
    /// before reading the switch back; a flip that did not land says so on its row.
    private func verifyTimedFlip(_ key: String, wantOn: Bool, after: TimeInterval = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            self?.refreshSnapshot {
                guard let self = self, let row = self.systemRow(key) else { return }
                if row.isOn == wantOn {
                    self.timerFailures[key] = nil
                } else {
                    let want = wantOn ? "on" : "off"
                    self.timerFailures[key] = "the timer could not turn it \(want); it is still \(wantOn ? "off" : "on")"
                    dwarn("timer: \(key) did not turn \(want)")
                }
                self.refreshPanel()
            }
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
        kanbanError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Services.run("/bin/zsh", ["-lc", cmd], timeout: 20)
            // pm2 prints its table either way; the exit status and the timeout are what count.
            let why = r.timedOut || !r.launched ? r.failure : (r.ok ? nil : "pm2 could not \(stopping ? "stop" : "start") it (exit \(r.status ?? -1))")
            if let why = why { derr("kanban toggle failed: \(why)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.kanbanError = why
                self?.kanbanBusy = false
                self?.refreshSnapshot()
            }
        }
    }
}

// ── Headless probe: hidden sections are not read ────────────────────────────

extension SwitchboardApp {
    /// Hides Repos and Dev servers for this process only, takes a fresh
    /// snapshot, and checks both groups are gone and their helpers never ran.
    func probeVisibility() -> String {
        let d = UserDefaults.standard
        let before = d.stringArray(forKey: Visibility.sectionsKey)
        defer { d.set(before, forKey: Visibility.sectionsKey) }
        d.set(["system::Repos", "runtime::Dev servers"], forKey: Visibility.sectionsKey)
        let titles = panelSystemGroupsFresh().map(\.title)
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "ok  " : "FAIL") \(name)") }
        check("a hidden group is not drawn", !titles.contains("Repos") && !titles.contains("Dev servers"))
        check("a hidden group's helper never ran",
              sbSnapshot.probeReadAt["gitscan.py"] == nil && sbSnapshot.probeReadAt["devservers.py"] == nil)
        check("a shown group still reads", sbSnapshot.probeReadAt["jobs.py"] != nil && titles.contains("Schedules"))
        let hiddenCatalog = Visibility.hiddenTitles("runtime")
        check("the hidden title is known per tab", hiddenCatalog == ["Dev servers"])
        lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
        return lines.joined(separator: "\n")
    }
}

// ── Headless probe: the command runner ──────────────────────────────────────

/// Runs the four ways a command can end (clean, error, timeout, never started)
/// plus two pipe floods, and checks each is told apart. Touches nothing.
func probeShell() -> String {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let clean = Services.run("/usr/bin/true", [])
    check("a clean run with no output is ok, not a failure", clean.ok && clean.failure == nil && clean.out.isEmpty)

    let bad = Services.run("/bin/sh", ["-c", "echo partial; echo 'disk is full' >&2; exit 3"])
    check("an error exit is a failure with the program's own words",
          !bad.ok && bad.status == 3 && bad.failure == "sh: disk is full", bad.failure ?? "nil")

    let quiet = Services.run("/bin/sh", ["-c", "exit 4"])
    check("an error exit with nothing on stderr names the exit code",
          quiet.failure == "sh stopped with an error (exit 4)", quiet.failure ?? "nil")

    let t0 = Date()
    let slow = Services.run("/bin/sleep", ["5"], timeout: 0.5)
    check("a hung command is stopped at its cap and says so",
          slow.timedOut && Date().timeIntervalSince(t0) < 2.5 && (slow.failure ?? "").contains("took longer"), slow.failure ?? "nil")

    let missing = Services.run("/nonexistent/tool", [])
    check("a program that is not there is 'could not be started'",
          !missing.launched && missing.failure == "tool could not be started", missing.failure ?? "nil")

    let big = Services.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x"], timeout: 5)
    check("200 KB of output arrives whole", big.ok && big.out.count == 200000, "\(big.out.count)")

    let errFlood = Services.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' e >&2; echo done"], timeout: 5)
    check("200 KB on stderr does not wedge the call", errFlood.ok && errFlood.out == "done\n", errFlood.failure ?? errFlood.out)

    check("the helper name is the script, not python3",
          ShellResult.displayName("/usr/bin/env", ["python3", "/x/lib/gitscan.py", "list"]) == "gitscan.py")
    check("helperError reports the run's failure when there is no JSON",
          SwitchboardApp.helperError(bad) == "sh: disk is full")
    let good = Services.run("/bin/sh", ["-c", "echo '{\"ok\": true}'"])
    check("helperError is nil for an ok answer", SwitchboardApp.helperError(good) == nil)
    let refused = Services.run("/bin/sh", ["-c", "echo '{\"ok\": false, \"error\": \"no such job\"}'"])
    check("helperError keeps the helper's own error", SwitchboardApp.helperError(refused) == "no such job")
    check("the old output-only call still returns the output", Services.shell("/bin/echo", ["hi"]) == "hi\n")

    // Tool errors reach the owner in words.
    let plain: [(String, String)] = [
        ("Bootstrap failed: 5: Input/output error", "launchd would not load it; it may be loaded already, or its plist is broken"),
        ("\u{1B}[31m[PM2][ERROR] Process or Namespace kanban not found\u{1B}[39m", "pm2 has no process named kanban"),
        ("kill: 123: Operation not permitted", "macOS did not allow it (permission denied)"),
        ("zsh:1: command not found: pm2", "pm2 is not installed or not on the PATH"),
        ("pm2: command not found", "pm2 is not installed or not on the PATH"),
        ("[PM2] Applying action\n┌────┬──────┐\n│ id │ name │\n", "it failed without saying why"),
        ("", "it failed without saying why"),
    ]
    for (raw, want) in plain {
        let got = SwitchboardApp.plainError(raw)
        check("plain words for: \(raw.prefix(30).replacingOccurrences(of: "\n", with: " "))", got == want, got)
    }

    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

