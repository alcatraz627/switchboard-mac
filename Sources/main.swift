// main.swift
// Switchboard's entry point. With no flags it runs as a menu bar app; the
// flags below run one check headlessly and exit, reading only (except
// --probe-timers, which flips Keep Awake and puts it back).
//
//   --dump                  print every Machine-tab row
//   --dump-policy [--scope <dir>]
//   --snapshot <out.png> [--tab agents|usage|system|home|remote|scopes] [--light] [--scope <dir>] [--expand]
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
    let lines = probeCatalog().components(separatedBy: "\n").dropLast() + probeRedaction() + probeToggles() + probeReorder() + probeWhen()
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
if let out = argAfter("--snapshot-hover") {
    // Every item on, from a real snapshot and the real limits file, plus one waiting push.
    _ = delegate.panelSystemGroupsFresh()
    let usage = UsageStore()
    usage.loadClaude()
    var lines: [HoverLine] = usage.claude.filter { $0.id == "five_hour" || $0.id == "seven_day" }.map { w in
        .bar(label: w.id == "five_hour" ? "5h" : "Week", pct: w.pct,
             color: w.pct >= usage.dangerPct ? .red : w.pct >= usage.warnPct ? .orange : .green,
             resets: w.resetsAt.map { "in " + countdownText(to: $0, now: Date()) } ?? "")
    }
    lines.append(.note(icon: "hand.raised.fill", text: "1 waiting on you: Push switchboard-mac", tint: Color(nsColor: menuYellow)))
    lines += delegate.hoverLines(Set(HoverItem.allCases))
    let ok = snapshotHover(lines, to: out, dark: !args.contains("--light"))
    print(ok ? "wrote \(out)" : "snapshot failed")
    exit(ok ? 0 : 1)
}
if let out = argAfter("--snapshot") {
    let tab = argAfter("--tab") ?? "agents"
    BulbRow.startExpanded = args.contains("--expand")
    SystemRowView.startExpanded = args.contains("--expand")
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
