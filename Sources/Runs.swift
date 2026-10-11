// Runs.swift
// Timers and reminders that run on one chosen device. A shared list of templates
// and each device's runs live as small JSON files in `.reminders/` inside the notes
// folder, so they travel with the notes and need no network code of their own.
// Every file has one writer: the starter writes a request, the device that runs it
// writes its state. Spec: day-lanes specs/reminders.md.

import Foundation
import SwiftUI

/// A timer anyone can start again: label, minutes, colour. One file per template, so two devices rarely touch one.
struct RunTemplate: Identifiable, Equatable {
    let id: String
    var label: String
    var minutes: Int
    var color: String
    var created: Int64
}

/// One run as the files say it: the request, what its device last said, and whether a stop was asked for.
struct RunRecord: Identifiable, Equatable {
    var id: String
    var kind: String          // "timer" or "reminder"
    var label: String
    var color: String
    var totalMs: Int64
    var fireAt: Int64
    var target: String        // "mac" or "phone"
    var from: String
    var createdAt: Int64
    var template: String?
    var status: String?       // nil until the target picks it up
    var endMs: Int64?
    var remainMs: Int64?
    var updatedAt: Int64?
    var stateNote: String = ""
    var stopRequested = false

    static let finishedStatuses: Set<String> = ["done", "stopped", "missed", "rejected"]
    var finished: Bool { status.map(Self.finishedStatuses.contains) ?? false }
}

struct RunDeviceRun: Equatable {
    let run: String
    let label: String
    let endMs: Int64
}

struct RunDevice: Equatable {
    var seenAt: Int64
    var running: [RunDeviceRun]
}

/// What the countdown list tells the run files about.
enum RunEvent { case started, rescheduled, ringing, answered, removed, missed }

/// A run on the other device as one calm row; never an error.
struct RunRow: Identifiable, Equatable {
    let id: String
    let label: String
    let color: String
    let status: String        // waiting, running, paused, ringing, rejected, ...
    let endMs: Int64?
    let waitingSince: Int64?
    let note: String
    let stopRequested: Bool
}

final class Runs: ObservableObject {
    static let shared = Runs(timers: TimerStore.shared)

    static let timerGraceMs: Int64 = 2 * 60 * 1000
    static let reminderGraceMs: Int64 = 60 * 60 * 1000
    static let finishedKeepMs: Int64 = 24 * 60 * 60 * 1000
    static let unansweredKeepMs: Int64 = 7 * 24 * 60 * 60 * 1000
    static let deviceQuietMs: Int64 = 10 * 60 * 1000
    static let me = "mac", other = "phone"

    @Published private(set) var records: [RunRecord] = []
    @Published private(set) var templates: [RunTemplate] = []
    @Published private(set) var devices: [String: RunDevice] = [:]
    /// A calm sentence when something could not be sent; the one place a failed hand-off shows.
    @Published private(set) var notice: String?

    let timers: TimerStore
    /// False for demo and probe stores, which must never write into the notes folder.
    let writes: Bool
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    private var lastDevice: (running: [RunDeviceRun], at: Int64)?
    private var lastCleanup: Int64 = 0

    init(timers: TimerStore, writes: Bool? = nil) {
        self.timers = timers
        self.writes = writes ?? timers.recordsRuns
        timers.runHook = self
        // what is already in the folder shows before the first sync lands; reading never writes
        if folderReady { publish() }
    }

    static var root: String { NotesStore.dir + "/.reminders" }
    private func path(_ sub: String, _ name: String) -> String { Self.root + "/" + sub + "/" + name }
    private var folderReady: Bool { NotesStore.missingFolder == nil }

    /// Ids this Mac makes, and the phone's, start with r-. A timer from before runs existed has a UUID and stays local.
    static func isRunID(_ id: String) -> Bool { id.hasPrefix("r-") }
    func newID() -> String {
        let fm = FileManager.default
        while true {
            let id = "r-\(nowMs() / 1000)-" + String(format: "%04x", Int.random(in: 0..<65536))
            if !fm.fileExists(atPath: path("runs", id + ".json")) && !records.contains(where: { $0.id == id }) { return id }
        }
    }

    // ── Files ───────────────────────────────────────────────────────────────

    private func readJSON(_ p: String) -> [String: Any]? {
        FileManager.default.contents(atPath: p).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Atomic, so a reader sees the old file or the new one, never half of it.
    private func writeJSON(_ p: String, _ o: [String: Any]) {
        guard writes, folderReady else { return }
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        try? d.write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    private func names(_ sub: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Self.root + "/" + sub)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private func int(_ o: [String: Any], _ k: String) -> Int64? { (o[k] as? NSNumber)?.int64Value }

    /// Everything in `.reminders/`, read fresh. Unreadable or half-written files are skipped, not reported.
    private func readFiles() -> (templates: [RunTemplate], records: [RunRecord], devices: [String: RunDevice]) {
        var tpl: [RunTemplate] = []
        for f in names("templates") where f.hasSuffix(".json") {
            guard let o = readJSON(path("templates", f)), let id = o["id"] as? String, let label = o["label"] as? String,
                  let m = int(o, "minutes") else { continue }
            tpl.append(RunTemplate(id: id, label: label, minutes: Int(m), color: o["color"] as? String ?? "", created: int(o, "created") ?? 0))
        }
        tpl.sort { ($0.created, $1.id) > ($1.created, $0.id) }
        var recs: [RunRecord] = []
        let all = Set(names("runs"))
        for f in all where f.hasSuffix(".json") && !f.hasSuffix(".state.json") {
            let rid = String(f.dropLast(5))
            guard let o = readJSON(path("runs", f)), let kind = o["kind"] as? String, let target = o["target"] as? String,
                  let fire = int(o, "fire_at") else { continue }
            var r = RunRecord(id: rid, kind: kind, label: o["label"] as? String ?? "", color: o["color"] as? String ?? "",
                              totalMs: int(o, "total_ms") ?? 0, fireAt: fire, target: target, from: o["from"] as? String ?? "",
                              createdAt: int(o, "created_at") ?? fire, template: o["template"] as? String)
            if let s = readJSON(path("runs", rid + ".state.json")) {
                r.status = s["status"] as? String
                r.endMs = int(s, "end_ms"); r.remainMs = int(s, "remain_ms"); r.updatedAt = int(s, "updated_at")
                r.stateNote = s["note"] as? String ?? ""
            }
            r.stopRequested = all.contains(rid + ".stop")
            recs.append(r)
        }
        recs.sort { ($0.createdAt, $1.id) > ($1.createdAt, $0.id) }
        var devs: [String: RunDevice] = [:]
        for name in [Self.me, Self.other] {
            guard let o = readJSON(path("devices", name + ".json")), let seen = int(o, "seen_at") else { continue }
            let running = (o["running"] as? [[String: Any]] ?? []).compactMap { i -> RunDeviceRun? in
                guard let run = i["run"] as? String else { return nil }
                return RunDeviceRun(run: run, label: i["label"] as? String ?? "", endMs: int(i, "end_ms") ?? 0)
            }
            devs[name] = RunDevice(seenAt: seen, running: running)
        }
        return (tpl, recs, devs)
    }

    /// Reads the folder, then does what this Mac owes: picks up requests aimed at it, honours stops, tidies its own files.
    /// Called after each notes sync and when the Timers tab opens. Never raises a dialog.
    func reload() {
        guard folderReady else { return }
        publish()
        guard writes else { return }
        if ingest() { publish() }
        cleanup()
        writeDeviceIfNeeded()
    }

    private func publish() {
        let f = readFiles()
        if f.templates != templates { templates = f.templates }
        if f.records != records { records = f.records }
        if f.devices != devices { devices = f.devices }
    }

    // ── What this Mac owes ──────────────────────────────────────────────────

    /// Requests aimed at the Mac become timers once; a stop file ends a run; a late timer is missed, not rung.
    @discardableResult
    private func ingest() -> Bool {
        var changed = false
        let now = nowMs()
        for r in records where r.target == Self.me && !r.finished {
            if r.stopRequested {
                if let t = timers.timers.first(where: { $0.id == r.id }) { timers.remove(t) }
                else { writeState(r.id, "stopped") }
                changed = true
            } else if r.status == nil {
                pickUp(r, now: now)
                changed = true
            }
        }
        return changed
    }

    private func pickUp(_ r: RunRecord, now: Int64) {
        // the same request read twice is one timer
        if timers.timers.contains(where: { $0.id == r.id }) { writeState(r.id, "running", endMs: r.fireAt); return }
        let late = now - r.fireAt
        let color = r.color.isEmpty ? "blue" : r.color
        if r.kind == "timer" {
            if late > Self.timerGraceMs { writeState(r.id, "missed", note: "Arrived after its time"); return }
            let start = Date(timeIntervalSince1970: Double(min(now, r.createdAt)) / 1000)
            timers.add(label: r.label, color: color, fireAt: Date(timeIntervalSince1970: Double(r.fireAt) / 1000), id: r.id, start: start, remember: false)
        } else {
            // a reminder rings once even when late; past the grace it says when it was due
            var label = r.label, fire = Date(timeIntervalSince1970: Double(r.fireAt) / 1000)
            if late > 0 {
                if late > Self.reminderGraceMs { label += " (missed at \(Self.clockTime(fire)))" }
                fire = Date().addingTimeInterval(1)
            }
            timers.add(label: label, color: color, fireAt: fire, id: r.id, remember: false)
        }
    }

    static func clockTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// The countdown list changed: say so in the run's state. A run started anywhere on the Mac gets its request on first sight.
    func timerEvent(_ t: SBTimer, _ e: RunEvent) {
        guard writes, folderReady, Self.isRunID(t.id) else { return }
        if !FileManager.default.fileExists(atPath: path("runs", t.id + ".json")) {
            writeJSON(path("runs", t.id + ".json"), request(id: t.id, kind: "timer", label: t.label, color: t.color,
                                                          totalMs: Int64(t.total * 1000), fireAt: ms(t.fireAt), target: Self.me,
                                                          createdAt: ms(t.start), template: nil))
        }
        switch e {
        case .started, .rescheduled: writeState(t.id, "running", endMs: ms(t.fireAt))
        case .ringing: writeState(t.id, "ringing", endMs: ms(t.fireAt))
        case .answered: writeState(t.id, "done")
        case .removed: writeState(t.id, t.running ? "stopped" : "done")
        case .missed: writeState(t.id, "missed", note: "Due while Switchboard was closed")
        }
        publish()
        writeDeviceIfNeeded()
    }

    private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    private func request(id: String, kind: String, label: String, color: String, totalMs: Int64, fireAt: Int64,
                         target: String, createdAt: Int64, template: String?) -> [String: Any] {
        ["id": id, "kind": kind, "label": label, "color": tagColorName(color) ?? "", "total_ms": totalMs, "fire_at": fireAt,
         "target": target, "from": Self.me, "created_at": createdAt, "template": template ?? NSNull(), "note": NSNull()]
    }

    /// Writes the target's word on a run. A finished run is final: a late event never revives it.
    private func writeState(_ id: String, _ status: String, endMs: Int64? = nil, note: String = "") {
        let p = path("runs", id + ".state.json")
        let old = readJSON(p)
        if let s = old?["status"] as? String, RunRecord.finishedStatuses.contains(s), s != status { return }
        if let o = old, o["status"] as? String == status, int(o, "end_ms") == endMs, o["note"] as? String == note { return }
        writeJSON(p, ["status": status, "updated_at": nowMs(), "end_ms": endMs.map { $0 as Any } ?? NSNull(), "remain_ms": NSNull(), "note": note])
        NotesSync.shared.commit("run: \(status)")
    }

    // ── What the owner starts ───────────────────────────────────────────────

    /// Starts a timer on one device. On this Mac it runs at once; for the phone the request is written, an immediate
    /// sync is asked for, and the row reads "Waiting for Phone" until the phone answers. Returns the run's id.
    @discardableResult
    func start(label: String, color: String, fireAt: Date, on device: String, template: String? = nil) -> String? {
        let id = newID()
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? "Timer" : label
        let now = nowMs()
        if device == Self.other {
            guard writes, folderReady else { notice = "Phone runs need the notes folder, which is not there. Nothing was started."; return nil }
            notice = nil
            writeJSON(path("runs", id + ".json"), request(id: id, kind: "timer", label: name, color: color,
                                                        totalMs: max(1, ms(fireAt) - now), fireAt: ms(fireAt), target: device, createdAt: now, template: template))
            NotesSync.shared.commit("run: request")
            NotesSync.shared.syncSoon()
            publish()
            return id
        }
        if writes, folderReady {
            writeJSON(path("runs", id + ".json"), request(id: id, kind: "timer", label: name, color: color,
                                                        totalMs: max(1, ms(fireAt) - now), fireAt: ms(fireAt), target: device, createdAt: now, template: template))
        }
        timers.add(label: name, color: color, fireAt: fireAt, id: id)
        publish()
        return id
    }

    /// Asks the device running a run to end it. Until it does, the row says stopping.
    func requestStop(_ id: String) {
        guard writes, folderReady, let r = records.first(where: { $0.id == id }), !r.finished, !r.stopRequested else { return }
        // an empty file, as the Pi writes it
        try? FileManager.default.createDirectory(atPath: Self.root + "/runs", withIntermediateDirectories: true)
        try? Data().write(to: URL(fileURLWithPath: path("runs", id + ".stop")), options: .atomic)
        NotesSync.shared.commit("run: stop requested")
        NotesSync.shared.syncSoon()
        publish()
    }

    @discardableResult
    func saveTemplate(label: String, minutes: Int, color: String) -> RunTemplate? {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard writes, folderReady, !l.isEmpty, minutes >= 1 else { return nil }
        let now = nowMs()
        let t = RunTemplate(id: "t-\(now / 1000)-" + String(format: "%04x", Int.random(in: 0..<65536)), label: l, minutes: minutes, color: tagColorName(color) ?? "", created: now)
        writeJSON(path("templates", t.id + ".json"), ["id": t.id, "label": t.label, "minutes": t.minutes, "color": t.color, "kind": "timer", "created": t.created])
        NotesSync.shared.commit("template: add")
        publish()
        return t
    }

    func removeTemplate(_ id: String) {
        guard writes, folderReady else { return }
        let p = path("templates", id + ".json")
        guard FileManager.default.fileExists(atPath: p) else { return }
        try? FileManager.default.removeItem(atPath: p)
        NotesSync.shared.commit("template: remove")
        publish()
    }

    // ── The other device ────────────────────────────────────────────────────

    /// How long since the phone last said anything: its newest run state or device file. Nil when never heard.
    func staleSeconds(_ device: String = other, now: Int64? = nil) -> Int? {
        var signals: [Int64] = devices[device].map { [$0.seenAt] } ?? []
        signals += records.filter { $0.target == device }.compactMap(\.updatedAt)
        guard let newest = signals.max() else { return nil }
        return Int(max(0, ((now ?? nowMs()) - newest) / 1000))
    }

    /// "as of 3 min ago" once it is older than two minutes; nothing before that.
    static func staleLabel(_ seconds: Int?) -> String? {
        guard let s = seconds, s >= 120 else { return nil }
        return "as of " + (s >= 3600 ? "\(s / 3600) h ago" : "\(s / 60) min ago")
    }

    /// Runs on the phone that are not over, newest first: what was sent, what the phone says it runs, a calm line for a refusal.
    func phoneRows(now: Int64? = nil) -> [RunRow] {
        let t = now ?? nowMs()
        var rows: [RunRow] = records.filter { $0.target == Self.other && (!$0.finished || $0.status == "rejected" && t - ($0.updatedAt ?? t) < 10 * 60 * 1000) }.map { r in
            RunRow(id: r.id, label: r.label, color: r.color, status: r.status ?? "waiting", endMs: r.endMs ?? (r.status == nil ? nil : r.fireAt),
                   waitingSince: r.status == nil ? r.createdAt : nil, note: r.stateNote, stopRequested: r.stopRequested)
        }
        let known = Set(records.map(\.id))
        for d in devices[Self.other]?.running ?? [] where !known.contains(d.run) {
            rows.append(RunRow(id: d.run, label: d.label, color: "", status: "running", endMs: d.endMs, waitingSince: nil, note: "", stopRequested: false))
        }
        return rows
    }

    // ── Keeping tidy ────────────────────────────────────────────────────────

    /// Removes what this Mac owns once stale: its own runs 24 hours after they ended, requests it sent that nobody ever
    /// answered after 7 days, and a state or stop file whose request is gone (once it is ten minutes old).
    func cleanup(force: Bool = false) {
        let now = nowMs()
        guard writes, force || now - lastCleanup > 60_000 else { return }
        lastCleanup = now
        let fm = FileManager.default
        var removed = 0
        for f in names("runs") {
            let rid = String(f.split(separator: ".", maxSplits: 1).first ?? "")
            let p = path("runs", f)
            guard let r = records.first(where: { $0.id == rid }) else {
                // a state or stop file whose request is not here; leave a fresh one, its request may be syncing
                let age = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? 0
                if f != rid + ".json", age > 600 { try? fm.removeItem(atPath: p); removed += 1 }
                continue
            }
            guard f == rid + ".json" else { continue }
            let doneLongAgo = r.target == Self.me && r.finished && now - (r.updatedAt ?? now) > Self.finishedKeepMs
            let unanswered = r.status == nil && r.from == Self.me && now - r.createdAt > Self.unansweredKeepMs
            guard doneLongAgo || unanswered else { continue }
            for suffix in [".json", ".state.json", ".stop"] where fm.fileExists(atPath: path("runs", rid + suffix)) {
                try? fm.removeItem(atPath: path("runs", rid + suffix)); removed += 1
            }
        }
        if removed > 0 { NotesSync.shared.commit("runs: cleanup"); publish() }
    }

    /// Says what this Mac runs when that set changes, and again every ten minutes while anything runs.
    /// An idle Mac writes nothing, so history is not filled with heartbeats.
    func writeDeviceIfNeeded() {
        guard writes, folderReady else { return }
        let running = timers.running.filter { Self.isRunID($0.id) }
            .map { RunDeviceRun(run: $0.id, label: $0.label, endMs: ms($0.fireAt)) }.sorted { $0.run < $1.run }
        let now = nowMs()
        if let last = lastDevice {
            if last.running == running && (running.isEmpty || now - last.at < Self.deviceQuietMs) { return }
        } else if running.isEmpty { return }
        writeJSON(path("devices", Self.me + ".json"), ["seen_at": now, "running": running.map { ["run": $0.run, "label": $0.label, "end_ms": $0.endMs] as [String: Any] }])
        lastDevice = (running, now)
        NotesSync.shared.commit("device: mac")
    }
}

// ── The Timers tab: the phone's runs ────────────────────────────────────────

/// What runs on the phone, muted under the Mac's own timers, with how old the news is.
struct PhoneRunsSection: View {
    @ObservedObject var runs: Runs

    var body: some View {
        // a slow tick, so "as of" and the waiting time keep up without a timer per row
        TimelineView(.periodic(from: .now, by: 5)) { tl in
            let now = Int64(tl.date.timeIntervalSince1970 * 1000)
            let rows = runs.phoneRows(now: now)
            if !rows.isEmpty {
                let stale = runs.staleSeconds(now: now)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "iphone").font(.sbIcon(9.5))
                        Text("On the phone").font(PT.section)
                        if let l = Runs.staleLabel(stale) { Text(l).font(PT.caption).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    .foregroundStyle(.secondary).padding(.leading, 4)
                    Card {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            PhoneRunRow(row: r, now: now, runs: runs)
                        }
                    }
                    .opacity((stale ?? 0) >= 15 * 60 ? 0.5 : 0.8)
                }
            }
        }
    }
}

private struct PhoneRunRow: View {
    let row: RunRow
    let now: Int64
    let runs: Runs

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(row.color.isEmpty ? Color.secondary : timerColor(row.color)).frame(width: si(9), height: si(9))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(PT.label).lineLimit(1).truncationMode(.middle)
                if row.status == "rejected", !row.note.isEmpty {
                    Text(row.note).font(PT.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            status
            if row.stopRequested {
                Text("stopping").font(PT.caption).foregroundStyle(.tertiary)
            } else if row.status != "rejected" {
                Button { runs.requestStop(row.id) } label: { Image(systemName: "xmark.circle").font(.sbIcon(11)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Ask the phone to stop it")
            }
        }
        .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV + 1)
    }

    @ViewBuilder private var status: some View {
        switch row.status {
        case "waiting":
            Label("Waiting for Phone" + (row.waitingSince.map { " · " + waited($0) } ?? ""), systemImage: "clock")
                .font(PT.caption).foregroundStyle(.secondary).lineLimit(1)
        case "ringing":
            Label("Ringing", systemImage: "bell.fill").font(PT.caption).foregroundStyle(.secondary)
        case "paused":
            Label("Paused", systemImage: "pause.circle").font(PT.caption).foregroundStyle(.secondary)
        case "rejected":
            Label("Not started", systemImage: "info.circle").font(PT.caption).foregroundStyle(.secondary)
        default:
            if let end = row.endMs { Text(clock(Double(end - now) / 1000)).font(.sb(13, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary) }
            else { Label("Running", systemImage: "timer").font(PT.caption).foregroundStyle(.secondary) }
        }
    }

    private func waited(_ since: Int64) -> String {
        let s = max(0, (now - since) / 1000)
        return s < 60 ? "\(s) s" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h"
    }
}

// ── Probe ───────────────────────────────────────────────────────────────────

/// The run files in the scratch notes folder: a request becomes a timer once, a late one is missed, a stop ends it,
/// the phone's runs read back as calm rows, and nothing here says "failed" or raises a dialog.
func probeRuns() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    // timers of the probe's own, so real ones are never read, started or cleared
    let realKey = TimerStore.key
    TimerStore.key = "switchboard.timers.countdowns.probe-runs"
    defer { AppDefaults.store.removeObject(forKey: TimerStore.key); TimerStore.key = realKey }
    AppDefaults.store.removeObject(forKey: TimerStore.key)
    let ts = TimerStore()
    ts.chimeAloud = false
    defer { ts.stop() }
    let runs = Runs(timers: ts, writes: true)
    let fm = FileManager.default
    let root = Runs.root
    try? fm.removeItem(atPath: root)
    func put(_ rel: String, _ o: Any?) {
        let p = root + "/" + rel
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let o { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]).write(to: URL(fileURLWithPath: p)) }
        else { fm.createFile(atPath: p, contents: Data()) }
    }
    func json(_ rel: String) -> [String: Any]? { fm.contents(atPath: root + "/" + rel).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    func state(_ id: String) -> String? { json("runs/\(id).state.json")?["status"] as? String }
    let now = runs.nowMs()
    func req(_ id: String, fire: Int64, kind: String = "timer", target: String = "mac", from: String = "phone", created: Int64? = nil) -> [String: Any] {
        ["id": id, "kind": kind, "label": "Probe \(id)", "color": "orange", "total_ms": 600_000, "fire_at": fire,
         "target": target, "from": from, "created_at": created ?? now, "template": NSNull(), "note": NSNull()]
    }

    put("runs/r-p-1.json", req("r-p-1", fire: now + 600_000))
    runs.reload()
    check("a request aimed at the Mac becomes one timer", ts.timers.filter { $0.id == "r-p-1" }.count == 1, "\(ts.timers.count)")
    check("and its state says running, ending when the request said", state("r-p-1") == "running" && (json("runs/r-p-1.state.json")?["end_ms"] as? NSNumber)?.int64Value == now + 600_000)
    runs.reload()
    check("the same request read twice does not start a second timer", ts.timers.filter { $0.id == "r-p-1" }.count == 1)

    put("runs/r-p-2.json", req("r-p-2", fire: now - 5 * 60_000))
    runs.reload()
    check("a timer that arrives after its time becomes missed and never starts", state("r-p-2") == "missed" && !ts.timers.contains { $0.id == "r-p-2" })

    put("runs/r-p-3.json", req("r-p-3", fire: now - 30 * 60_000, kind: "reminder"))
    runs.reload()
    let late = ts.timers.first { $0.id == "r-p-3" }
    check("a reminder up to an hour late still rings, once", late != nil && late?.label == "Probe r-p-3" && late.map { $0.fireAt.timeIntervalSinceNow < 5 } == true)
    put("runs/r-p-4.json", req("r-p-4", fire: now - 90 * 60_000, kind: "reminder"))
    runs.reload()
    check("one over the hour rings once and says when it was due", ts.timers.first { $0.id == "r-p-4" }?.label.contains("(missed at ") == true,
          ts.timers.first { $0.id == "r-p-4" }?.label ?? "none")

    put("runs/r-p-1.stop", nil)
    runs.reload()
    check("a stop file ends the run and the state says stopped", !ts.timers.contains { $0.id == "r-p-1" } && state("r-p-1") == "stopped")

    // events from the countdown list write the state; a finished run is final
    let t5 = SBTimer(id: "r-p-5", label: "Event", color: "green", start: Date(), fireAt: Date().addingTimeInterval(60))
    runs.timerEvent(t5, .started)
    check("a timer started on the Mac writes its request and state", json("runs/r-p-5.json")?["target"] as? String == "mac" && state("r-p-5") == "running")
    runs.timerEvent(t5, .ringing)
    check("ringing is written", state("r-p-5") == "ringing")
    runs.timerEvent(t5, .answered)
    runs.timerEvent(t5, .rescheduled)
    check("answered is done, and a later event does not revive it", state("r-p-5") == "done")

    // starting for the phone: written at once, no waiting, no error anywhere
    let before = NotesStore.shared.error
    let sent = runs.start(label: "Pasta", color: "red", fireAt: Date().addingTimeInterval(600), on: "phone")
    let sentJSON = sent.flatMap { json("runs/\($0).json") }
    check("a run for the phone is a request file, aimed at the phone, sent from the Mac", sentJSON?["target"] as? String == "phone" && sentJSON?["from"] as? String == "mac")
    check("it shows as Waiting for Phone at once", runs.phoneRows().first { $0.id == sent }?.status == "waiting")
    check("no error text or dialog comes with it", runs.notice == nil && NotesStore.shared.error == before)
    check("the phone never ran it, so no timer starts here", !ts.timers.contains { $0.id == sent })

    // the phone answers
    if let id = sent {
        put("runs/\(id).state.json", ["status": "running", "updated_at": now, "end_ms": now + 600_000, "remain_ms": NSNull(), "note": ""])
        runs.reload()
        let row = runs.phoneRows().first { $0.id == id }
        check("the phone's word turns the row into a running one with its end time", row?.status == "running" && row?.endMs == now + 600_000, row?.status ?? "none")
        check("under two minutes old shows no 'as of' label", Runs.staleLabel(runs.staleSeconds(now: now + 30_000)) == nil)
        check("older shows how old", Runs.staleLabel(runs.staleSeconds(now: now + 7 * 60_000)) == "as of 7 min ago", Runs.staleLabel(runs.staleSeconds(now: now + 7 * 60_000)) ?? "nil")
        runs.requestStop(id)
        check("asking the phone to stop writes only a stop file, and the row says stopping",
              fm.fileExists(atPath: root + "/runs/\(id).stop") && state(id) == "running" && runs.phoneRows().first { $0.id == id }?.stopRequested == true)
    }
    put("runs/r-p-6.json", req("r-p-6", fire: now + 600_000, target: "phone", from: "mac"))
    put("runs/r-p-6.state.json", ["status": "rejected", "updated_at": now, "end_ms": NSNull(), "remain_ms": NSNull(), "note": "4 timers already running"])
    runs.reload()
    check("a refusal is a calm line with the phone's own words", runs.phoneRows().first { $0.id == "r-p-6" }?.note == "4 timers already running")

    // what this Mac says it runs: once on change, not again within ten minutes
    runs.writeDeviceIfNeeded()
    let seen = json("devices/mac.json")?["seen_at"] as? NSNumber
    check("the Mac's device file lists what it runs", (json("devices/mac.json")?["running"] as? [[String: Any]])?.contains { $0["run"] as? String == "r-p-3" } == true)
    runs.writeDeviceIfNeeded()
    check("an unchanged set is not rewritten inside ten minutes", (json("devices/mac.json")?["seen_at"] as? NSNumber) == seen)

    // tidying: its own finished run after 24 hours, an unanswered request after 7 days; fresher ones stay
    put("runs/r-old.json", req("r-old", fire: now - 3_000_000, target: "mac"))
    put("runs/r-old.state.json", ["status": "done", "updated_at": now - 25 * 3_600_000, "end_ms": NSNull(), "remain_ms": NSNull(), "note": ""])
    put("runs/r-fresh.json", req("r-fresh", fire: now - 3_000_000, target: "mac"))
    put("runs/r-fresh.state.json", ["status": "done", "updated_at": now - 23 * 3_600_000, "end_ms": NSNull(), "remain_ms": NSNull(), "note": ""])
    put("runs/r-lost.json", req("r-lost", fire: now, target: "phone", from: "mac", created: now - 8 * 86_400_000))
    runs.reload()
    runs.cleanup(force: true)
    check("a run it finished 25 hours ago is removed, all three files", !fm.fileExists(atPath: root + "/runs/r-old.json") && !fm.fileExists(atPath: root + "/runs/r-old.state.json"))
    check("one finished 23 hours ago stays", fm.fileExists(atPath: root + "/runs/r-fresh.json"))
    check("a request nobody answered for 8 days is removed", !fm.fileExists(atPath: root + "/runs/r-lost.json"))

    // templates: shared, newest first
    let a = runs.saveTemplate(label: "Tea", minutes: 3, color: "green")
    Thread.sleep(forTimeInterval: 0.01)
    let b = runs.saveTemplate(label: "Pasta", minutes: 10, color: "orange")
    check("a template is one file, and the list is newest first", a != nil && b != nil && runs.templates.first?.label == "Pasta" && json("templates/\(a?.id ?? "x").json")?["minutes"] as? Int == 3)
    runs.removeTemplate(a?.id ?? "")
    check("removing a template removes its file", !fm.fileExists(atPath: root + "/templates/\(a?.id ?? "x").json") && runs.templates.count == 1)

    try? fm.removeItem(atPath: root)
    return lines
}
