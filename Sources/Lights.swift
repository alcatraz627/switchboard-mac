// Lights.swift
// The Switchboard's Home tab: the WiZ smart bulbs on the home network, each
// with on/off, brightness, warmth and scenes. All protocol work is in
// lib/wiz.py; this file only calls it and draws the result.

import AppKit
import Foundation
import SwiftUI

struct Bulb: Identifiable, Equatable {
    let ip: String
    let mac: String
    var name: String
    var reachable: Bool
    var on: Bool
    var dimming: Int
    var temp: Int?
    var scene: Int?
    var sceneName: String?
    /// Set when the bulb is showing a colour rather than a white or a scene.
    var rgb: (r: Int, g: Int, b: Int)?
    var speed: Int?

    static func == (a: Bulb, b: Bulb) -> Bool {
        a.ip == b.ip && a.mac == b.mac && a.name == b.name && a.reachable == b.reachable && a.on == b.on
            && a.dimming == b.dimming && a.temp == b.temp && a.scene == b.scene && a.speed == b.speed
            && a.rgb?.r == b.rgb?.r && a.rgb?.g == b.rgb?.g && a.rgb?.b == b.rgb?.b
    }

    var id: String { mac }
    /// Speed applies to animated scenes; the bulb reports one only while it is in one.
    var isAnimatedScene: Bool { scene != nil && speed != nil }
    var title: String { name.isEmpty ? "Bulb \(ip.split(separator: ".").last ?? "")" : name }

    init?(_ d: [String: Any]) {
        guard let ip = d["ip"] as? String, let mac = d["mac"] as? String else { return nil }
        self.ip = ip; self.mac = mac
        name = d["name"] as? String ?? ""
        reachable = d["reachable"] as? Bool ?? false
        on = d["on"] as? Bool ?? false
        dimming = (d["dimming"] as? NSNumber)?.intValue ?? 100
        temp = (d["temp"] as? NSNumber)?.intValue
        scene = (d["scene"] as? NSNumber)?.intValue
        sceneName = d["scene_name"] as? String
        speed = (d["speed"] as? NSNumber)?.intValue
        if let c = d["rgb"] as? [Any], c.count == 3,
           let r = (c[0] as? NSNumber)?.intValue, let g = (c[1] as? NSNumber)?.intValue,
           let b = (c[2] as? NSNumber)?.intValue, scene == nil {
            rgb = (r, g, b)
        }
    }

    /// What the second line says the bulb is showing.
    var modeText: String {
        if let s = sceneName { return s }
        if let c = rgb { return String(format: "#%02X%02X%02X", c.r, c.g, c.b) }
        return temp.map { "\($0)K" } ?? ""
    }
}

/// Hue (0-1) at full saturation and brightness, as the hex a bulb takes.
func hueHex(_ hue: Double) -> String {
    let c = NSColor(calibratedHue: CGFloat(hue), saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
    return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

enum WizCLI {
    static var script = AppPaths.lib("wiz.py")

    static func run(_ args: [String], timeout: TimeInterval = 8) -> (json: Any?, err: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, "could not start wiz.py") }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (nil, "wiz.py timed out") }
        p.waitUntilExit()
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let e = (obj as? [String: Any])?["error"] as? String { return (nil, e) }
        return (obj, p.terminationStatus == 0 ? nil : "wiz.py failed")
    }
}

final class LightsStore: ObservableObject {
    @Published private(set) var bulbs: [Bulb] = []
    @Published private(set) var discovering = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanStarted: Date?
    /// A scan that failed outright; a bulb's own failure lives in `failures`.
    @Published var error: String?
    @Published private(set) var busy: Set<String> = []
    /// When each bulb's unconfirmed change was sent, by MAC.
    @Published private(set) var pendingSince: [String: Date] = [:]
    @Published var failures: [String: String] = [:]
    private var lastPairs: [String: [String]] = [:]
    private let queue = DispatchQueue(label: "lights.store", qos: .userInitiated)

    /// Scan the network. Cheap (one broadcast, 3 s of listening), so it runs
    /// on every open; the last list stays on screen meanwhile.
    func discover() {
        guard !discovering else { return }
        discovering = true
        scanStarted = Date()
        queue.async { [weak self] in
            let r = WizCLI.run(["discover"])
            let list = (r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discovering = false
                self.lastScan = Date()
                // A failed scan keeps the list on screen; the status line says
                // it could not be refreshed and how old it is.
                if let e = r.err { self.error = e; dwarn("bulb scan failed: \(e)"); return }
                self.error = nil
                self.bulbs = list
            }
        }
    }

    /// Send one change to one bulb. The row shows the change at once; the
    /// bulb's own report replaces it, or the old state comes back on failure.
    func set(_ bulb: Bulb, _ pairs: [String]) {
        guard let i = bulbs.firstIndex(where: { $0.mac == bulb.mac }) else { return }
        let before = bulbs[i]
        bulbs[i] = Self.applying(pairs, to: before)
        busy.insert(bulb.mac)
        pendingSince[bulb.mac] = Date()
        failures[bulb.mac] = nil
        lastPairs[bulb.mac] = pairs
        queue.async { [weak self] in
            let r = WizCLI.run(["set", bulb.ip] + pairs)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy.remove(bulb.mac)
                self.pendingSince[bulb.mac] = nil
                guard let j = self.bulbs.firstIndex(where: { $0.mac == bulb.mac }) else { return }
                if let e = r.err {
                    self.bulbs[j] = before
                    self.failures[bulb.mac] = Self.plain(e)
                    dwarn("bulb \(bulb.ip) \(pairs.joined(separator: " ")): \(e)")
                    return
                }
                if let d = r.json as? [String: Any], var b = Bulb(d) {
                    b.name = self.bulbs[j].name
                    self.bulbs[j] = b
                }
            }
        }
    }

    func retry(_ bulb: Bulb) {
        if let pairs = lastPairs[bulb.mac] { set(bulb, pairs) }
    }

    /// The bulb as it will look once the change lands, for showing at once.
    static func applying(_ pairs: [String], to b: Bulb) -> Bulb {
        var n = b
        for p in pairs {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "state": n.on = kv[1] == "on"
            case "dimming": n.dimming = Int(kv[1]) ?? n.dimming
            case "temp": n.temp = Int(kv[1]); n.scene = nil; n.sceneName = nil; n.rgb = nil
            case "scene":
                n.scene = Int(kv[1]); n.rgb = nil
                n.sceneName = scenes.first { $0.0 == n.scene }?.1
            case "rgb":
                let h = kv[1]
                if h.count == 6, let v = Int(h, radix: 16) {
                    n.rgb = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF); n.scene = nil; n.sceneName = nil
                }
            case "speed": n.speed = Int(kv[1])
            default: break
            }
        }
        return n
    }

    /// wiz.py's messages, in the words the owner needs.
    static func plain(_ e: String) -> String {
        if e.contains("did not confirm") || e.contains("timed out") {
            return "The bulb did not answer. It may be switched off at the wall or out of Wi-Fi range."
        }
        return e
    }

    func setAll(on: Bool) {
        for b in bulbs where b.reachable && b.on != on { set(b, ["state=\(on ? "on" : "off")"]) }
    }

    func rename(_ bulb: Bulb, to name: String) {
        _ = WizCLI.run(["name", bulb.mac, name])
        if let i = bulbs.firstIndex(where: { $0.mac == bulb.mac }) { bulbs[i].name = name }
    }

    func loadForSnapshot() {
        let r = WizCLI.run(["discover"])
        bulbs = (r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? []
        error = r.err
        lastScan = Date()
    }

    static let scenes: [(Int, String)] = [
        (11, "Warm White"), (30, "Golden White"), (12, "Daylight"), (13, "Cool White"),
        (14, "Night Light"), (15, "Focus"), (16, "Relax"), (29, "Candlelight"), (6, "Cozy"),
        (10, "Bedtime"), (9, "Wake Up"), (18, "TV Time"), (5, "Fireplace"), (3, "Sunset"),
        (1, "Ocean"), (7, "Forest"), (8, "Pastel Colors"), (17, "True Colors"), (2, "Romance"),
        (4, "Party"), (26, "Club"), (31, "Pulse"),
    ]
}

// ── The tab ─────────────────────────────────────────────────────────────────

struct LightsTabView: View {
    @ObservedObject var lights: LightsStore

    private var scanState: ReadingState {
        if let e = lights.error {
            return lights.bulbs.isEmpty ? .failed("Could not look for bulbs: \(e)")
                                        : .stale(lights.lastScan ?? Date(), e)
        }
        if let d = lights.lastScan { return .fresh(d) }
        return .loading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SBStyle.gap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SBGroupHeader(name: "Lights")
                    Spacer()
                    if lights.bulbs.contains(where: { $0.reachable }) {
                        Button("All off") { lights.setAll(on: false) }.controlSize(.small)
                        Button("All on") { lights.setAll(on: true) }.controlSize(.small)
                    }
                    Button { lights.discover() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Look for bulbs on the network again")
                }
                .padding(.trailing, 4)
                ReadingStatus(state: scanState, staleAfter: 600,
                              busySince: lights.discovering && !lights.bulbs.isEmpty ? lights.scanStarted : nil,
                              retry: lights.error != nil ? { lights.discover() } : nil)
                    .padding(.horizontal, 4)
                SBCard {
                    if lights.bulbs.isEmpty && !lights.discovering && lights.error == nil {
                        Text("No bulbs answered on this network.")
                            .font(SBStyle.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, SBStyle.rowH).padding(.vertical, 8)
                    }
                    ForEach(Array(lights.bulbs.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { Divider().padding(.leading, SBStyle.rowH) }
                        BulbRow(bulb: b, lights: lights)
                    }
                }
            }
            Text("WiZ bulbs on your home network, controlled directly over the LAN. No account or cloud involved.")
                .font(SBStyle.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(SBStyle.gap)
    }
}

struct BulbRow: View {
    let bulb: Bulb
    @ObservedObject var lights: LightsStore
    @State private var dim: Double = 50
    @State private var warm: Double = 2700
    @State private var hue: Double = 0
    @State private var editing = false
    @State private var showColour = BulbRow.startExpanded

    /// Headless renders set this (--expand) so the colour strip can be checked.
    static var startExpanded = false

    private static let swatches: [(String, String)] = [
        ("FF3B30", "Red"), ("FF9500", "Orange"), ("FFD60A", "Yellow"), ("34C759", "Green"),
        ("00C7BE", "Teal"), ("007AFF", "Blue"), ("AF52DE", "Purple"), ("FF2D55", "Pink"),
    ]

    private var busy: Bool { lights.busy.contains(bulb.mac) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: bulb.on ? "lightbulb.fill" : "lightbulb")
                    .foregroundStyle(bulb.on ? Color.yellow : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bulb.title).font(SBStyle.label)
                    Text(bulb.reachable
                         ? (bulb.on ? "\(bulb.dimming)% · \(bulb.modeText)" : "off")
                         : "not answering")
                        .font(SBStyle.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showColour.toggle() } label: {
                    Image(systemName: "paintpalette").font(.system(size: 11))
                        .foregroundStyle(showColour ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Colour")
                .disabled(!bulb.reachable || !bulb.on)
                Menu {
                    Section("Scene") {
                        ForEach(LightsStore.scenes, id: \.0) { s in
                            Button(s.1) { lights.set(bulb, ["scene=\(s.0)"]) }
                        }
                    }
                    if bulb.isAnimatedScene {
                        Section("Scene speed") {
                            ForEach([("Slow", 40), ("Normal", 100), ("Fast", 180)], id: \.1) { s in
                                Button(s.0 + ((bulb.speed ?? 100) == s.1 ? "  ✓" : "")) {
                                    lights.set(bulb, ["speed=\(s.1)"])
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Rename…") { rename() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(!bulb.reachable)
                if let since = lights.pendingSince[bulb.mac] { PendingMark(since: since) }
                Toggle("", isOn: Binding(get: { bulb.on },
                                         set: { lights.set(bulb, ["state=\($0 ? "on" : "off")"]) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!bulb.reachable)
                    .allowsHitTesting(!busy)
            }
            if bulb.on && bulb.reachable {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? dim : Double(bulb.dimming) }, set: { dim = $0 }),
                           in: 10...100,
                           onEditingChanged: { e in
                               if e { dim = Double(bulb.dimming); editing = true }
                               else { editing = false; lights.set(bulb, ["dimming=\(Int(dim))"]) }
                           }).controlSize(.mini)
                    Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? warm : Double(bulb.temp ?? 2700) }, set: { warm = $0 }),
                           in: 2200...6500,
                           onEditingChanged: { e in
                               if e { warm = Double(bulb.temp ?? 2700); editing = true }
                               else { editing = false; lights.set(bulb, ["temp=\(Int(warm / 100) * 100)"]) }
                           }).controlSize(.mini)
                        .help("Warm to cool white")
                }
                .padding(.leading, 24)
                .allowsHitTesting(!busy)
                if showColour { colourRow.padding(.leading, 24).allowsHitTesting(!busy) }
            }
            if let f = lights.failures[bulb.mac] {
                RowFailure(message: f, retry: { lights.retry(bulb) },
                           dismiss: { lights.failures[bulb.mac] = nil })
                    .padding(.horizontal, -SBStyle.rowH).padding(.leading, 24)
            }
        }
        .padding(.horizontal, SBStyle.rowH).padding(.vertical, SBStyle.rowV + 1)
        .opacity(bulb.reachable ? 1 : 0.55)
    }

    /// A hue strip for any colour, eight quick swatches, and a way back to white.
    /// It stays inside the panel: the system colour window would take focus and
    /// close the popover mid-pick.
    private var colourRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: $hue, in: 0...1, onEditingChanged: { e in
                if !e { lights.set(bulb, ["rgb=\(hueHex(hue))"]) }
            })
            .controlSize(.mini)
            .onAppear {
                if let c = bulb.rgb {
                    hue = Double(NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                         blue: CGFloat(c.b) / 255, alpha: 1).hueComponent)
                }
            }
            .background(
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4).clipShape(Capsule())
            )
            .help("Drag to pick a colour")
            HStack(spacing: 6) {
                ForEach(Self.swatches, id: \.0) { s in
                    Button { lights.set(bulb, ["rgb=\(s.0)"]) } label: {
                        Circle().fill(Color(nsColor: NSColor.fromHex(s.0) ?? .gray))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain).help(s.1)
                }
                Spacer()
                Button("White") { lights.set(bulb, ["temp=\(bulb.temp ?? 2700)"]) }
                    .controlSize(.mini)
                    .help("Back to warm or cool white")
            }
        }
    }

    private func rename() {
        let a = NSAlert()
        a.messageText = "Name this bulb"
        a.informativeText = "\(bulb.ip) · \(bulb.mac)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = bulb.name
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { lights.rename(bulb, to: field.stringValue) }
    }
}
