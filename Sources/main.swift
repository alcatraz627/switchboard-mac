// main.swift
// Switchboard's entry point. With no flags it runs as a menu bar app; the
// flags below run one check headlessly and exit, reading only (except
// --probe-timers, which flips Keep Awake and puts it back).
//
//   --dump                  print every Machine-tab row
//   --dump-policy [--scope <dir>]
//   --snapshot <out.png> [--tab <tab id, e.g. agents, rules, notes, controls>] [--light] [--scope <dir>] [--expand]
//   --probe-timers          exercise the timed-flip engine on Keep Awake
//   --probe-controls        write volume, mute and brightness back to themselves
//   --probe-approve         approve a planted push in a scratch folder, never ~/.claude
//   --probe-shell           tell a clean, failed, hung and missing command apart
//   --probe-snapshot        one snapshot per burst of requests; a wait gets a fresh one
//   --probe-catalog         the list tabs' parsing, failure, preview and search
//   --open                  open the panel shortly after launch

import AppKit
import Foundation
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = SwitchboardApp()

func argAfter(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let args = CommandLine.arguments
if args.contains("--version") {
    print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    exit(0)
}
if args.contains("--dump") {
    print(delegate.dumpSwitchboard())
    exit(0)
}
if args.contains("--probe-timers") {
    let report = delegate.probeSystemTimers()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-snapshot") {
    let report = delegate.probeSnapshot()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-approve") {
    let report = probeApprove()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-shell") {
    let report = probeShell()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-catalog") {
    let lines = probeCatalog().components(separatedBy: "\n").dropLast() + probeCheckpoints() + probeRedaction() + probeToggles() + probeReorder() + probeWhen()
    print((lines + [lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed"]).joined(separator: "\n"))
    exit(lines.contains { $0.hasPrefix("FAIL") } ? 1 : 0)
}
if args.contains("--probe-visibility") {
    let report = delegate.probeVisibility()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-timers-tab") {
    let report = probeTimers()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-notes") {
    let report = probeNotes()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-transcript") {
    let report = probeTranscript()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--probe-controls") {
    let report = probeControls()
    print(report)
    exit(report.hasSuffix("all passed") ? 0 : 1)
}
if args.contains("--dump-policy") {
    let store = PolicyStore()
    if let d = argAfter("--scope"), let root = PolicyCLI.root(of: d) { store.scope = .project(root) }
    let r = PolicyCLI.load(store.scope)
    store.applyForSnapshot(items: r.items, projects: r.projects, error: r.error)
    print(policyDump(store))
    exit(r.error == nil ? 0 : 1)
}
if let out = argAfter("--snapshot-when") {
    let v = WhenPanel(title: "Switch later, keeping Allow until then", presets: WhenPreset.short,
                      choices: ["To Ask", "To Block"], extra: [("Cancel the timed change", {})], onPick: { _, _ in })
    let dark = !args.contains("--light")
    let host = NSHostingView(rootView: v.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    let ok = (try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))) != nil
    print(ok ? "wrote \(out)" : "snapshot failed")
    exit(ok ? 0 : 1)
}
if args.contains("--time-tabs") {
    // How long each list tab takes to read its source: the wait before an opened tab fills in.
    for (tab, read) in catalogReaders.sorted(by: { $0.key < $1.key }) {
        let t0 = Date()
        let rows = read().reduce(0) { $0 + $1.rows.count }
        print("\(tab): \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(rows) rows")
    }
    exit(0)
}
if args.contains("--probe-quick") {
    let r = probeQuickCycle() + "\n" + probePointer().joined(separator: "\n")
    print(r)
    exit(r.contains("FAIL") ? 1 : 0)
}
if args.contains("--probe-sessions") {
    let r = probeSessions(scanFile: argAfter("--scan-file"))
    print(r)
    exit(r.hasSuffix("all passed") ? 0 : 1)
}
if let out = argAfter("--snapshot-quick") {
    // One quick page, drawn from the real stores (read only): --page home|limits|approvals|bulbs|notes|timers|controls|models
    let page = QuickPage(rawValue: argAfter("--page") ?? "home") ?? .home
    let policy = PolicyStore()
    policy.setNeeds(NeedsYou.items(), refresh: {})
    let usage = UsageStore()
    usage.loadClaude()
    let lights = LightsStore()
    if page == .bulbs {
        lights.discover()
        let until = Date().addingTimeInterval(8)
        while lights.discovering && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    NotesStore.shared.load()
    let state = QuickState()
    state.page = page
    // every badge kind, with the longest wording seen live, so wrapping shows
    let problems = [Problem(text: "refresh session index failed (exit 1)", tab: "runtime", level: .error, query: "refresh session index")]
        + [Problem(text: "1 gate is off", tab: "rules", level: .warn, query: "gates")]
        + Problem.hooks(unwired: 8, missing: 0)
    state.badges = [StatusBadge(id: "approvals", icon: "hand.raised.fill", text: "12 waiting", kind: .waiting, help: "", opens: .approvals)]
        + problems.enumerated().map { StatusBadge(problem: $1, index: $0) }
        + [StatusBadge(id: "down", icon: "bolt.slash.fill", text: "Down: kanban, session hub", kind: .error, help: "", tab: "runtime"),
           StatusBadge(id: "timer", icon: Icons.tab["timers"] ?? "timer", text: "Tea · 4:05", kind: .info, help: "", tab: "timers")]
    // Pages that read on appear are filled first, so the card is measured at its real size.
    let controls = ControlsStore()
    if page == .controls { controls.load(devices: false) }
    if page == .models { policy.systemGroups = delegate.panelSystemGroupsFresh(); policy.systemReadOnce = true }
    if page == .sessions {
        // a recorded scan when given (--scan-file), else a live one from the installed scanner
        if let f = argAfter("--scan-file"), let d = FileManager.default.contents(atPath: f) { SessionsStore.shared.show(d) }
        else if let s = Integrations.scanScript { SessionsStore.shared.show(Data(Services.run("/bin/bash", [s, "--quick"], timeout: 10).out.utf8)) }
        else { SessionsStore.shared.show(Data("{\"live\": []}".utf8)) }
    }
    let card = QuickCard(state: state, policy: policy, usage: usage, lights: lights, notes: NotesStore.shared, controls: controls, openTab: { _ in })
    let ok = snapshotCard(AnyView(card), to: out)
    print(ok ? "wrote \(out)" : "snapshot failed")
    exit(ok ? 0 : 1)
}
if let out = argAfter("--snapshot") {
    let tab = argAfter("--tab") ?? "agents"
    BulbRow.startExpanded = args.contains("--expand")
    SystemRowView.startExpanded = args.contains("--expand")
    // Demo timers go under a key of their own, set before the store first loads.
    if args.contains("--demo-states") {
        TimerStore.key = "switchboard.timers.countdowns.demo"
        UserDefaults.standard.removeObject(forKey: TimerStore.key)
    }
    if args.contains("--notifications-off") { TimerStore.shared.notificationsOff = true }
    // Tabs that draw Machine groups, their own or ones moved to them, need the probe.
    let usesSystem = tab == "system" || tab == "remote" || SystemTabView.groupHome.values.contains(tab)
    let fresh = usesSystem ? delegate.panelSystemGroupsFresh() : []
    let ok = snapshotPolicyPanel(to: out, dark: !args.contains("--light"), scopeDir: argAfter("--scope"), tab: tab,
                                 system: tab == "remote" ? [] : fresh,
                                 remote: tab == "remote" ? delegate.panelRemoteGroups() : [])
    print(ok ? "wrote \(out)" : "snapshot failed")
    exit(ok ? 0 : 1)
}

app.delegate = delegate
app.run()
