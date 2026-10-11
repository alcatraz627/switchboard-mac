// PhoneTabs.swift
// Usage, Bulbs and Agents as list-tab rows, for the phone's Switchboard page
// (--json and --act). They read the same stores and helpers the panel's own tabs
// use, but are kept out of catalogReaders so the app never preloads them (a bulb
// scan listens on the network for seconds).

import AppKit
import Foundation

/// Every tab the phone can read or press: the panel's list tabs plus the three below.
let phoneReaders: [String: () -> [SystemGroup]] = catalogReaders.merging([
    "usage": PhoneTabs.usage,
    "bulbs": PhoneTabs.bulbs,
    "agents": PhoneTabs.agents,
    "approvals": PhoneTabs.approvals,
]) { a, _ in a }

enum PhoneTabs {
    // ── Approvals ──

    /// What waits on the owner, as the Approvals tab groups it. A row's key is its hold file, and its
    /// Approve, Cancel (Deny for a Claude prompt) buttons are the ones --act presses.
    /// SWITCHBOARD_NEEDS_ROOT points it at a scratch folder, so a walk never touches a real hold.
    static func approvals() -> [SystemGroup] {
        if let scratch = ProcessInfo.processInfo.environment["SWITCHBOARD_NEEDS_ROOT"], !scratch.isEmpty {
            NeedsYou.rootOverride = scratch
            NeedsYou.probing = true
        }
        let items = NeedsYou.items()
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kinds: [NeedItem.Kind: String] = [.push: "push", .ask: "ask", .prompt: "prompt", .armedApproval: "armed", .unreadable: "unreadable"]
        return NeedsYou.groups(items, refresh: {}).map { g in
            SystemGroup(title: g.title, rows: g.rows.map { r in
                var r = r
                if let k = r.key, let i = byID[k] {
                    r.phone = ["kind": kinds[i.kind] ?? "", "session": i.sessionID, "approved": i.approved,
                               "live": i.sessionDir != nil, "held_at": i.since.map { Int($0.timeIntervalSince1970) } ?? 0]
                }
                return r
            }, status: g.status)
        }
    }

    // ── Usage ──

    static func usage() -> [SystemGroup] {
        let store = UsageStore()
        store.reload()
        let now = Date()
        func group(_ title: String, _ windows: [UsageWindow], warn: Int, danger: Int, empty: ReadingState) -> SystemGroup {
            let rows = windows.map { w -> SystemRow in
                let reset = w.resetsAt.map { $0 > now ? "in " + countdownText(to: $0, now: now) : "now" } ?? ""
                var row = SystemRow(label: w.label, state: .ok, note: reset.isEmpty ? "\(w.pct)% used" : "\(w.pct)% used, resets \(reset)")
                row.key = title.lowercased() + "." + w.id
                row.phone = ["percent": w.pct, "reset": reset,
                             "level": w.pct >= danger ? "danger" : w.pct >= warn ? "warn" : "ok"]
                if let at = w.resetsAt { row.phone["resets_at"] = Int(at.timeIntervalSince1970) }
                return row
            }
            return SystemGroup(title: title, rows: rows, status: rows.isEmpty ? empty : nil)
        }
        return [group("Claude", store.claude, warn: store.warnPct, danger: store.dangerPct, empty: store.claudeState),
                group("Codex", store.codex, warn: store.codexWarnPct, danger: 75, empty: store.codexState)]
    }

    // ── Bulbs ──

    static func bulbs() -> [SystemGroup] {
        let r = WizCLI.run(["discover"])
        let list = (r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? []
        if let e = r.err, list.isEmpty {
            return [SystemGroup(title: "Bulbs", rows: [], status: .failed("Could not look for bulbs: \(e)"))]
        }
        return [SystemGroup(title: "Bulbs", rows: list.map(bulbRow),
                            status: list.isEmpty ? .unavailable("No bulbs answered on this network.") : nil)]
    }

    /// The colour a button's text names: a six-digit hex (with or without #) or one of the panel's swatch names.
    static func colourHex(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let s = BulbRow.swatches.first(where: { $0.1.lowercased() == t.lowercased() }) { return s.0 }
        let h = t.hasPrefix("#") ? String(t.dropFirst()) : t
        return h.count == 6 && h.allSatisfy(\.isHexDigit) ? h.uppercased() : nil
    }

    static func bulbRow(_ b: Bulb) -> SystemRow {
        let note = !b.reachable ? "not answering" : b.on ? "\(b.dimming)%" + (b.modeText.isEmpty ? "" : " · \(b.modeText)") : "off"
        var row = SystemRow(label: b.title, state: b.on && b.reachable ? .on(.systemYellow) : .off, note: note)
        row.key = b.mac
        row.enabled = b.reachable
        row.labelIsName = true
        row.phone = ["brightness": b.dimming, "reachable": b.reachable, "on": b.on && b.reachable,
                     "color": b.rgb.map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) } ?? "",
                     "mode": b.modeText]
        if let t = b.temp { row.phone["temp"] = t }
        guard b.reachable else { return row }
        func set(_ pairs: [String]) -> String? { WizCLI.run(["set", b.ip] + pairs).err.map(LightsStore.plain) }
        row.action = { _ = set(["state=\(b.on ? "off" : "on")"]) }
        row.buttons = [
            RowButton(label: "On", kind: .run({ set(["state=on"]) }), doing: "turn \(b.title) on"),
            RowButton(label: "Off", kind: .run({ set(["state=off"]) }), doing: "turn \(b.title) off"),
            RowButton(label: "Brightness", kind: .ask(placeholder: "10-100") { text in
                guard let n = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return "\(text) is not a number from 10 to 100" }
                return set(["dimming=\(min(100, max(10, n)))"])
            }, doing: "set the brightness"),
            RowButton(label: "Colour", kind: .ask(placeholder: "RRGGBB, a swatch name or white") { text in
                if text.lowercased() == "white" { return set(["temp=\(b.temp ?? 2700)"]) }
                guard let hex = colourHex(text) else { return "\(text) is not a colour (use RRGGBB, a swatch name or white)" }
                return set(["rgb=\(hex)"])
            }, doing: "set the colour"),
        ]
        row.phone["swatches"] = BulbRow.swatches.map { ["hex": $0.0, "name": $0.1] }
        return row
    }

    // ── Agents ──

    /// What agents may do as the owner: pol.sh's policies, grouped as the Agents tab groups them (read only).
    static func agents() -> [SystemGroup] {
        let r = PolicyCLI.load(.global)
        if let e = r.error { return [SystemGroup(title: "Agents", rows: [], status: .failed(e))] }
        var order: [String] = []
        var byGroup: [String: [PolicyItem]] = [:]
        for i in r.items {
            if byGroup[i.group] == nil { order.append(i.group) }
            byGroup[i.group, default: []].append(i)
        }
        return order.map { g in
            SystemGroup(title: g, rows: byGroup[g]!.map { i -> SystemRow in
                let value = i.value.cli
                var row = SystemRow(label: i.label, state: .ok, note: i.help.isEmpty ? value : "\(value) · \(i.help)")
                row.key = i.key
                row.phone = ["value": value]
                if case .toggle = i.kind { row.phone["allowed"] = value == "allow" }
                return row
            })
        }
    }
}
