// main.swift
// Switchboard's entry point. With no flags it runs as a menu bar app; the
// flags below run one check headlessly and exit, reading only (except
// --probe-timers, which flips Keep Awake and puts it back).
//
//   --dump                  print every Machine-tab row
//   --dump-policy [--scope <dir>]
//   --snapshot <out.png> [--tab agents|usage|system|home|scopes] [--light] [--scope <dir>] [--expand]
//   --probe-timers          exercise the timed-flip engine on Keep Awake
//   --open                  open the panel shortly after launch

import AppKit
import Foundation

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
if args.contains("--dump-policy") {
    let store = PolicyStore()
    if let d = argAfter("--scope"), let root = PolicyCLI.root(of: d) { store.scope = .project(root) }
    let r = PolicyCLI.load(store.scope)
    store.applyForSnapshot(items: r.items, projects: r.projects, error: r.error)
    print(policyDump(store))
    exit(r.error == nil ? 0 : 1)
}
if let out = argAfter("--snapshot") {
    let tab = argAfter("--tab") ?? "agents"
    BulbRow.startExpanded = args.contains("--expand")
    let ok = snapshotPolicyPanel(to: out, dark: !args.contains("--light"), scopeDir: argAfter("--scope"), tab: tab,
                                 system: tab == "system" ? delegate.panelSystemGroupsFresh() : [])
    print(ok ? "wrote \(out)" : "snapshot failed")
    exit(ok ? 0 : 1)
}

app.delegate = delegate
app.run()
