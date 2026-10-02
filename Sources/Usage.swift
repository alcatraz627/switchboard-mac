// Usage.swift
// The Switchboard's Usage tab: how much of each Claude and Codex usage window
// is spent, when each resets, and the thresholds that act on those numbers.
//
// Claude's windows come from what Claude Code hands the statusline
// (~/.claude/widgets/.rate-limits-raw.json, every window it sends, falling
// back to .limits.json). Codex's come from the cache the Codex usage gate
// keeps; the panel never starts Codex unless the owner asks it to.

import AppKit
import Foundation
import SwiftUI

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let pct: Int
    let resetsAt: Date?
}

struct CodexResetCredit: Equatable {
    let title: String
    let expiresAt: Date?
}

final class UsageStore: ObservableObject {
    @Published private(set) var claude: [UsageWindow] = []
    @Published private(set) var claudeAsOf: Date?
    @Published private(set) var codex: [UsageWindow] = []
    @Published private(set) var codexAsOf: Date?
    @Published private(set) var codexPlan: String?
    @Published private(set) var codexResets: [CodexResetCredit] = []

    /// Where a Claude bar turns amber and red.
    @Published var warnPct: Int = UserDefaults.standard.integer(forKey: "rateLimitWarningThreshold") {
        didSet { saveZone("rateLimitWarningThreshold", warnPct) }
    }
    @Published var dangerPct: Int = UserDefaults.standard.integer(forKey: "rateLimitDangerThreshold") {
        didSet { saveZone("rateLimitDangerThreshold", dangerPct) }
    }

    /// Where a Codex bar turns amber. Its red line is the policy's Codex seat
    /// stand-down, so only the warning needs a setting of its own.
    @Published var codexWarnPct: Int = UserDefaults.standard.integer(forKey: "codexWarningThreshold") {
        didSet { saveZone("codexWarningThreshold", codexWarnPct) }
    }

    init() {
        UserDefaults.standard.register(defaults: ["rateLimitWarningThreshold": 70, "rateLimitDangerThreshold": 90,
                                                  "codexWarningThreshold": 60])
        warnPct = UserDefaults.standard.integer(forKey: "rateLimitWarningThreshold")
        dangerPct = UserDefaults.standard.integer(forKey: "rateLimitDangerThreshold")
        codexWarnPct = UserDefaults.standard.integer(forKey: "codexWarningThreshold")
    }

    static var widgetsDir = NSString(string: "~/.claude/widgets").expandingTildeInPath
    static var codexGate = NSString(string: "~/.claude/adapters/codex/bin/codex-usage-gate.py").expandingTildeInPath
    private let queue = DispatchQueue(label: "usage.store", qos: .userInitiated)

    private func saveZone(_ key: String, _ v: Int) {
        guard UserDefaults.standard.integer(forKey: key) != v else { return }
        UserDefaults.standard.set(v, forKey: key)
    }

    /// Both are file reads and cheap. Opening the panel never starts Codex:
    /// its numbers come from the cache the usage gate keeps, and only the
    /// owner's "Ask Codex now" asks Codex itself.
    func reload() {
        loadClaude()
        loadCodexCache()
    }

    @Published private(set) var codexBusySince: Date?
    /// Why the last "Ask Codex now" did not produce a new reading.
    @Published private(set) var codexRefreshError: String?

    static var codexCache = NSString(string: "~/.claude/adapters/codex/state/limits.json").expandingTildeInPath
    static var codexMute = NSString(string: "~/.claude/.no-codex-usage-gate").expandingTildeInPath

    /// Set when a usage file exists but cannot be parsed, so it does not read as "no reading yet".
    private var claudeUnreadable = false
    private var codexUnreadable = false

    var claudeState: ReadingState {
        if let d = claudeAsOf, !claude.isEmpty { return .fresh(d) }
        if claudeUnreadable { return .failed("The Claude usage file exists but could not be read (it is not valid JSON).") }
        return .unavailable("No usage reading yet. It arrives with the next statusline render.")
    }

    var codexState: ReadingState {
        if let d = codexAsOf, !codex.isEmpty {
            if let e = codexRefreshError { return .stale(d, e) }
            return .fresh(d)
        }
        if let e = codexRefreshError { return .failed(e) }
        if codexUnreadable { return .failed("The Codex usage cache exists but could not be read (it is not valid JSON).") }
        if !FileManager.default.fileExists(atPath: Self.codexGate) {
            return .unavailable("Codex usage needs the Codex adapter in ~/.claude.")
        }
        if FileManager.default.fileExists(atPath: Self.codexMute) {
            return .unavailable("No reading yet. The Codex usage gate is muted, so nothing asks Codex.")
        }
        return .unavailable("No reading yet. One arrives when a Codex seat runs, or ask Codex now.")
    }

    // ── Claude ──

    func loadClaude() {
        let raw = Self.widgetsDir + "/.rate-limits-raw.json"
        let legacy = Self.widgetsDir + "/.limits.json"
        var windows: [UsageWindow] = []
        var asOf: Date?
        if let d = FileManager.default.contents(atPath: raw),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !o.isEmpty {
            asOf = modified(raw)
            for (key, v) in o {
                guard let w = v as? [String: Any],
                      let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                windows.append(UsageWindow(id: key, label: Self.claudeLabel(key), pct: Int(pct.rounded()),
                                           resetsAt: Self.epoch(w["resets_at"])))
            }
        } else if let d = FileManager.default.contents(atPath: legacy),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            asOf = modified(legacy)
            if let p = (o["5h"] as? [String: Any])?["pct"] as? NSNumber {
                windows.append(UsageWindow(id: "five_hour", label: "5 hours", pct: p.intValue, resetsAt: Self.epoch(o["resets_at"])))
            }
            if let p = (o["week"] as? [String: Any])?["pct"] as? NSNumber {
                windows.append(UsageWindow(id: "seven_day", label: "Week", pct: p.intValue, resetsAt: Self.epoch(o["resets_at_weekly"])))
            }
        }
        claude = windows.sorted { Self.order($0.id) < Self.order($1.id) }
        claudeAsOf = asOf
        let fm = FileManager.default
        claudeUnreadable = windows.isEmpty && (fm.fileExists(atPath: raw) || fm.fileExists(atPath: legacy))
            && [raw, legacy].allSatisfy { p in
                guard let d = fm.contents(atPath: p) else { return true }
                return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) == nil
            }
    }

    /// five_hour, seven_day, then any per-model window, by name.
    static func order(_ id: String) -> String {
        id == "five_hour" ? "0" : id == "seven_day" ? "1" : "2" + id
    }

    static func claudeLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "5 hours"
        case "seven_day": return "Week"
        default:
            // seven_day_opus → "Week · Opus": a per-model window, named by model.
            let model = key.replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "five_hour_", with: "")
                .replacingOccurrences(of: "_", with: " ").capitalized
            return (key.hasPrefix("five_hour") ? "5 hours · " : "Week · ") + model
        }
    }

    // ── Codex ──

    /// The usage gate's last good reading, as it left it on disk.
    func loadCodexCache() {
        guard let d = FileManager.default.contents(atPath: Self.codexCache) else { codexUnreadable = false; return }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { codexUnreadable = true; return }
        codexUnreadable = false
        applyCodex(o, asOf: modified(Self.codexCache) ?? Date())
    }

    /// For --demo-states snapshots only.
    func demoRefreshFailure(_ why: String) { codexRefreshError = why }

    /// The one path that asks Codex itself (it starts a short-lived
    /// `codex app-server`), so it runs only when the owner clicks for it.
    func askCodexNow() {
        guard codexBusySince == nil else { return }
        if FileManager.default.fileExists(atPath: Self.codexMute) {
            codexRefreshError = "the Codex usage gate is muted (~/.claude/.no-codex-usage-gate)"
            return
        }
        codexBusySince = Date()
        codexRefreshError = nil
        queue.async { [weak self] in
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            // Capped: a Codex that never answers used to leave the spinner running until restart.
            let r = Services.run("/usr/bin/env", ["python3", Self.codexGate, "--fresh"], timeout: 60, environment: env)
            let verdict = r.timedOut || !r.launched ? "UNKNOWN: " + (r.failure ?? "Codex did not answer") : r.out
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.codexBusySince = nil
                // The gate prints "PASS<TAB>UNKNOWN: <why>" when it could not read.
                if let u = verdict.range(of: "UNKNOWN: ") {
                    let why = verdict[u.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    self.codexRefreshError = why.isEmpty ? "Codex did not answer" : String(why.prefix(140))
                    dwarn("codex usage refresh failed: \(why)")
                } else if let crash = r.failure, !(r.out.hasPrefix("PASS") || r.out.hasPrefix("GATED")) {
                    // A crash prints no verdict; the cached numbers would look freshly read.
                    self.codexRefreshError = String(crash.prefix(140))
                    dwarn("codex usage refresh failed: \(crash)")
                } else {
                    self.loadCodexCache()
                }
            }
        }
    }

    func applyCodex(_ o: [String: Any], asOf: Date = Date()) {
        codexAsOf = asOf
        var windows: [UsageWindow] = []
        let byId = o["rateLimitsByLimitId"] as? [String: [String: Any]]
            ?? ["codex": (o["rateLimits"] as? [String: Any]) ?? [:]]
        for (id, lim) in byId {
            let name = id == "codex" ? "Codex" : ((lim["limitName"] as? String) ?? id)
            for slot in ["primary", "secondary"] {
                guard let w = lim[slot] as? [String: Any],
                      let pct = (w["usedPercent"] as? NSNumber)?.intValue else { continue }
                let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                let span = mins == 10080 ? "Week" : mins == 300 ? "5 hours" : mins >= 60 ? "\(mins / 60)h" : "\(mins)m"
                windows.append(UsageWindow(id: "\(id).\(slot)", label: id == "codex" ? span : "\(span) · \(name)",
                                           pct: pct, resetsAt: Self.epoch(w["resetsAt"])))
            }
        }
        codex = windows.sorted { ($0.id.hasPrefix("codex") ? "0" : "1") + $0.id < ($1.id.hasPrefix("codex") ? "0" : "1") + $1.id }
        codexPlan = (o["rateLimits"] as? [String: Any])?["planType"] as? String
        let credits = ((o["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]]) ?? []
        codexResets = credits.filter { ($0["status"] as? String) == "available" }.map {
            CodexResetCredit(title: ($0["title"] as? String) ?? "Reset", expiresAt: Self.epoch($0["expiresAt"]))
        }
    }

    // ── Helpers ──

    static func epoch(_ v: Any?) -> Date? {
        if let n = v as? NSNumber, n.doubleValue > 0 { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = v as? String, let d = Double(s), d > 0, d < 9_000_000_000 { return Date(timeIntervalSince1970: d) }
        return nil
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

}

// ── The tab ─────────────────────────────────────────────────────────────────

struct UsageTabView: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var policy: PolicyStore
    private var now: Date { policy.now }

    var body: some View {
        VStack(alignment: .leading, spacing: SBStyle.gap) {
            if !policy.hiddenSections.contains("usage::Claude") {
            section("Claude", link: ("Usage page", "https://claude.ai/settings/usage"), state: usage.claudeState) {
                ForEach(usage.claude) { w in
                    UsageBarRow(window: w, now: now,
                                color: zoneColor(w.pct, warn: usage.warnPct, danger: usage.dangerPct),
                                ticks: w.id == "seven_day" || w.id == "five_hour"
                                    ? [(usage.warnPct, "warn"), (usage.dangerPct, "danger"), (standDown, "stand-down")]
                                    : [(usage.warnPct, "warn"), (usage.dangerPct, "danger")])
                }
                ZoneSlider(label: "Warn at", value: $usage.warnPct, tint: .orange)
                ZoneSlider(label: "Danger at", value: $usage.dangerPct, tint: .red)
            }
            }
            if !policy.hiddenSections.contains("usage::Codex") {
            section("Codex", link: ("Usage page", "https://chatgpt.com/settings/usage?tab=overview"),
                    state: usage.codexState, busySince: usage.codexBusySince,
                    refresh: { usage.askCodexNow() }, refreshLabel: "Ask Codex now") {
                ForEach(usage.codex) { w in
                    UsageBarRow(window: w, now: now,
                                color: zoneColor(w.pct, warn: usage.codexWarnPct, danger: codexGate),
                                ticks: w.id.hasPrefix("codex") ? [(usage.codexWarnPct, "warn"), (codexGate, "seat stand-down")]
                                                               : [(usage.codexWarnPct, "warn")])
                }
                ZoneSlider(label: "Warn at", value: $usage.codexWarnPct, tint: .orange)
                if !usage.codexResets.isEmpty {
                    let f = DateFormatter()
                    let _ = f.dateFormat = "d MMM"
                    note("\(usage.codexResets.count) free full reset\(usage.codexResets.count == 1 ? "" : "s") available"
                         + (usage.codexResets.compactMap { $0.expiresAt }.min().map { ", first expires \(f.string(from: $0))" } ?? ""))
                }
            }
            }
            // The thresholds that act on these numbers live in the policy
            // store; they render here with the same rows the Agents tab uses.
            let limits = policy.items.filter { $0.group == "Limits" && $0.key.hasSuffix("_pct") }
            if !limits.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SBGroupHeader(name: "What acts on these numbers")
                    SBCard {
                        ForEach(Array(limits.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, SBStyle.rowH) }
                            PolicyRowView(item: item, store: policy)
                        }
                    }
                }
            }
        }
        .padding(SBStyle.gap)
    }

    private var standDown: Int { policyNumber("ops.usage_gate_pct") ?? 90 }
    private var codexGate: Int { policyNumber("ops.codex_gate_pct") ?? 75 }

    private func policyNumber(_ key: String) -> Int? {
        if case .number(let d)? = policy.items.first(where: { $0.key == key })?.value { return Int(d) }
        return nil
    }

    private func zoneColor(_ pct: Int, warn: Int, danger: Int) -> Color {
        pct >= danger ? .red : pct >= warn ? .orange : .green
    }

    private func note(_ s: String) -> some View {
        Text(s).font(SBStyle.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SBStyle.rowH).padding(.vertical, 4)
    }

    /// A reading's section: header and link, its status line (age, failure,
    /// or why there is nothing), then the card.
    private func section<C: View>(_ title: String, link: (String, String), state: ReadingState,
                                  busySince: Date? = nil, refresh: (() -> Void)? = nil,
                                  refreshLabel: String = "Refresh",
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SBGroupHeader(name: title)
                Spacer()
                if let r = refresh {
                    if let since = busySince { PendingMark(since: since) }
                    else {
                        Button(refreshLabel, action: r).buttonStyle(.link).font(SBStyle.caption)
                            .help("Starts Codex briefly to read fresh numbers (a few seconds)")
                    }
                }
                Link(destination: URL(string: link.1)!) {
                    Label(link.0, systemImage: "arrow.up.right").font(SBStyle.caption).labelStyle(.titleAndIcon)
                }
                .help(link.1)
            }
            .padding(.trailing, 4)
            ReadingStatus(state: state, staleAfter: 3600).padding(.horizontal, 4)
            SBCard { content() }
        }
    }
}

/// One window: label, a bar with threshold ticks, the percentage, and when it resets.
struct UsageBarRow: View {
    let window: UsageWindow
    let now: Date
    let color: Color
    let ticks: [(Int, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(SBStyle.label)
                Spacer()
                Text("\(window.pct)%").font(SBStyle.mono)
                if let r = window.resetsAt, r > now {
                    Text("resets in \(countdownText(to: r, now: now))").font(SBStyle.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(4, g.size.width * CGFloat(min(window.pct, 100)) / 100))
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                        Rectangle().fill(Color.primary.opacity(0.45))
                            .frame(width: si(1.5), height: si(10))
                            .offset(x: g.size.width * CGFloat(min(max(t.0, 0), 100)) / 100 - 0.75)
                            .help("\(t.1) at \(t.0)%")
                    }
                }
            }
            .frame(height: 7)
        }
        .padding(.horizontal, SBStyle.rowH).padding(.vertical, SBStyle.rowV + 1)
    }
}

/// A 50–100% slider for one of the Claude usage zones.
struct ZoneSlider: View {
    let label: String
    @Binding var value: Int
    let tint: Color
    @State private var draft: Double = 0
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: si(6), height: si(6))
            Text(label).font(SBStyle.label)
            Spacer()
            Slider(value: Binding(get: { dragging ? draft : Double(value) },
                                  set: { draft = ($0 / 5).rounded() * 5 }),
                   in: 50...100,
                   onEditingChanged: { editing in
                       if editing { draft = Double(value); dragging = true }
                       else { dragging = false; value = Int(draft) }
                   })
                .sbControlSize(.small)
                .frame(width: sc(108))
                // up raises the threshold, 5 points a notch, as every slider in the app turns
                .scrollSteps("usage-threshold-" + label, inContent: true, stepper: .slider()) { by in
                    value = min(100, max(50, value - by * 5))
                }
            Text("\(dragging ? Int(draft) : value)%").font(SBStyle.mono).frame(width: sw(36), alignment: .trailing)
        }
        .padding(.horizontal, SBStyle.rowH).padding(.vertical, SBStyle.rowV)
    }
}

func relative(_ d: Date, now: Date) -> String { countdownText(to: now, now: d) + " ago" }
