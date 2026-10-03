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
        let out = Pipe(), errPipe = Pipe()
        p.standardOutput = out
        p.standardError = errPipe
        guard (try? p.run()) != nil else { return (nil, "The bulb helper could not be started.") }
        var data = Data(), errData = Data()
        let done = DispatchGroup()
        done.enter(); DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.leave() }
        done.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); done.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (nil, "The bulbs did not answer in time.") }
        p.waitUntilExit()
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let e = (obj as? [String: Any])?["error"] as? String { return (nil, plainErrorText(e)) }
        guard p.terminationStatus != 0 else { return (obj, nil) }
        // A crash prints its reason on stderr; without it the owner only learns that something failed.
        let why = String(data: errData.suffix(2048), encoding: .utf8).map { plainErrorText($0, fallback: "") } ?? ""
        return (obj, why.isEmpty ? "The bulb helper stopped without saying why." : why)
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
    /// When each bulb was last seen on, by MAC, kept across launches: a bulb
    /// stays a row on the hover card for a while after it goes off.
    @Published private(set) var lastOn: [String: Date] = LightsStore.loadLastOn()
    private var lastPairs: [String: [String]] = [:]
    private let queue = DispatchQueue(label: "lights.store", qos: .userInitiated)

    /// Scan the network. Cheap (one broadcast, 3 s of listening), so it runs
    /// on every open; the last list stays on screen meanwhile.
    func discover() {
        guard !discovering else { return }
        discovering = true
        scanStarted = Date()
        queue.async { [weak self] in
            var r = WizCLI.run(["discover"])
            // A scan answers with a list; anything else is a fault, not "no bulbs".
            if r.err == nil, !(r.json is [[String: Any]]) { r.err = "The bulb scan gave an answer that could not be read." }
            let list = (r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discovering = false
                self.lastScan = Date()
                // A failed scan keeps the list on screen; the status line says
                // it could not be refreshed and how old it is.
                if let e = r.err { self.error = e; dwarn("bulb scan failed: \(e)"); return }
                self.error = nil
                self.bulbs = applyOrder(list, self.order)
                self.noteOn(list)
            }
        }
    }

    /// The owner's arrangement, by MAC; a bulb not in it goes at the end.
    private static let orderKey = "switchboard.bulbOrder"
    private var order: [String] { UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? [] }

    /// Move a bulb while it is dragged; `saveOrder` keeps it on the drop.
    func move(_ dragged: String, to target: String) {
        let ids = reordered(bulbs.map(\.id), moving: dragged, to: target)
        bulbs = applyOrder(bulbs, ids)
    }

    func saveOrder() { UserDefaults.standard.set(bulbs.map(\.id), forKey: Self.orderKey) }

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
                // a bulb switched off now was on until now
                if before.on { self.lastOn[bulb.mac] = Date(); self.saveLastOn() }
                self.noteOn([self.bulbs[j]])
            }
        }
    }

    private static let lastOnKey = "switchboard.bulbLastOn"
    private static func loadLastOn() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: lastOnKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }
    private func saveLastOn() {
        UserDefaults.standard.set(lastOn.mapValues(\.timeIntervalSince1970), forKey: Self.lastOnKey)
    }
    private func noteOn(_ list: [Bulb]) {
        var changed = false
        for b in list where b.on { lastOn[b.mac] = Date(); changed = true }
        if changed { saveLastOn() }
    }

    /// How long a bulb that went off keeps its row on the hover card.
    static let rowAfterOff: TimeInterval = 2 * 3600
    /// On now, or on within the last two hours: shown as a row, not a chip.
    static func keepsRow(_ b: Bulb, lastOn: Date?, now: Date = Date()) -> Bool {
        b.on && b.reachable || (lastOn.map { now.timeIntervalSince($0) < rowAfterOff } ?? false)
    }

    func retry(_ bulb: Bulb) {
        if let name = failedRename[bulb.mac] { rename(bulb, to: name) }
        else if let pairs = lastPairs[bulb.mac] { set(bulb, pairs) }
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

    /// Names a rename could not save, by bulb, so Retry saves that name again.
    @Published var failedRename: [String: String] = [:]

    /// Save a bulb's display name. It shows at once and goes back if the save
    /// fails. Names live on this Mac, so a bulb that is not answering can be renamed.
    func rename(_ bulb: Bulb, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = bulbs.firstIndex(where: { $0.mac == bulb.mac }), bulbs[i].name != name else { return }
        let before = bulbs[i].name
        bulbs[i].name = name
        failures[bulb.mac] = nil
        failedRename[bulb.mac] = nil
        pendingSince[bulb.mac] = Date()
        queue.async { [weak self] in
            let r = WizCLI.run(["name", bulb.mac, name])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingSince[bulb.mac] = nil
                guard let e = r.err else { return }
                if let j = self.bulbs.firstIndex(where: { $0.mac == bulb.mac }) { self.bulbs[j].name = before }
                self.failedRename[bulb.mac] = name
                self.failures[bulb.mac] = "The name was not saved: \(e)"
                dwarn("bulb rename \(bulb.mac): \(e)")
            }
        }
    }

    func loadForSnapshot() {
        let r = WizCLI.run(["discover"])
        bulbs = applyOrder((r.json as? [[String: Any]])?.compactMap(Bulb.init) ?? [], order)
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
    @Environment(\.panelSpace) private var space

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
                        Button("All off") { lights.setAll(on: false) }.sbControlSize(.small)
                        Button("All on") { lights.setAll(on: true) }.sbControlSize(.small)
                    }
                    Button { lights.discover() } label: {
                        Image(systemName: "arrow.clockwise").font(.sbIcon(10))
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
                    ReorderStack(items: lights.bulbs, move: { lights.move($0, to: $1) }, commit: { lights.saveOrder() }) { i, b, grip in
                        VStack(spacing: 0) {
                            if i > 0 { Divider().padding(.leading, SBStyle.rowH) }
                            HStack(spacing: 0) {
                                grip.padding(.leading, 4)
                                BulbRow(bulb: b, lights: lights, nav: RowNav.forSpace(space, "home"))
                            }
                        }
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
    @ObservedObject var nav: RowNav
    @State private var dim: Double = 50
    @State private var warm: Double = 2700
    @State private var hue: Double = 0
    @State private var editing = false
    @State private var showColour = BulbRow.startExpanded
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    /// Headless renders set this (--expand) so the colour strip can be checked.
    static var startExpanded = false

    static let swatches: [(String, String)] = [
        ("FF3B30", "Red"), ("FF9500", "Orange"), ("FFD60A", "Yellow"), ("34C759", "Green"),
        ("00C7BE", "Teal"), ("007AFF", "Blue"), ("AF52DE", "Purple"), ("FF2D55", "Pink"),
    ]

    private var busy: Bool { lights.busy.contains(bulb.mac) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: bulb.on ? "lightbulb.fill" : "lightbulb")
                    .foregroundStyle(bulb.on ? Color.yellow : Color.secondary)
                    .frame(width: si(16))
                VStack(alignment: .leading, spacing: 1) {
                    if renaming {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.plain).font(SBStyle.label)
                            .focused($nameFocused)
                            .inputBox(focused: nameFocused)
                            .onSubmit { finishRename(save: true) }
                            // Escape lets go of the keyboard; letting go keeps the name, as clicking away does
                            .onExitCommand { nameFocused = false }
                            .onChange(of: nameFocused) { f in if !f && renaming { finishRename(save: true) } }
                    } else {
                        Text(bulb.title).font(SBStyle.label)
                            .contentShape(Rectangle())
                            .onTapGesture { startRename() }
                            .help("Click to rename")
                    }
                    Text(bulb.reachable
                         ? (bulb.on ? "\(bulb.dimming)% · \(bulb.modeText)" : "off")
                         : "not answering")
                        .font(SBStyle.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showColour.toggle(); nav.expanded = showColour ? bulb.id : nil } label: {
                    Image(systemName: "paintpalette").font(.sbIcon(11))
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
                    Button("Rename") { startRename() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.sbIcon(12)).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(!bulb.reachable)
                if let since = lights.pendingSince[bulb.mac] { PendingMark(since: since) }
                Toggle("", isOn: Binding(get: { bulb.on },
                                         set: { lights.set(bulb, ["state=\($0 ? "on" : "off")"]) }))
                    .toggleStyle(.switch).sbControlSize(.small).labelsHidden()
                    .disabled(!bulb.reachable)
                    .allowsHitTesting(!busy)
            }
            if bulb.on && bulb.reachable {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.sbIcon(10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? dim : Double(bulb.dimming) }, set: { dim = $0 }),
                           in: 10...100,
                           onEditingChanged: { e in
                               if e { dim = Double(bulb.dimming); editing = true }
                               else { editing = false; lights.set(bulb, ["dimming=\(Int(dim))"]) }
                           }).sbControlSize(.mini)
                        // up brightens, down dims, 5% a notch, as every slider in the app turns
                        .scrollSteps("bulb-dim-" + bulb.mac, inContent: true, stepper: .slider()) { by in
                            lights.set(bulb, ["dimming=\(Int(min(100, max(10, Double(bulb.dimming) - Double(by) * 5))))"])
                        }
                    Image(systemName: "thermometer.medium").font(.sbIcon(10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? warm : Double(bulb.temp ?? 2700) }, set: { warm = $0 }),
                           in: 2200...6500,
                           onEditingChanged: { e in
                               if e { warm = Double(bulb.temp ?? 2700); editing = true }
                               else { editing = false; lights.set(bulb, ["temp=\(Int(warm / 100) * 100)"]) }
                           }).sbControlSize(.mini)
                        .scrollSteps("bulb-temp-" + bulb.mac, inContent: true, stepper: .slider()) { by in
                            let t = min(6500, max(2200, Double(bulb.temp ?? 2700) - Double(by) * 200))
                            lights.set(bulb, ["temp=\(Int(t / 100) * 100)"])
                        }
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
        .keyRing(nav.focus == .row(bulb.id))
        // Return on the focused bulb opens its colour strip, as the palette button does
        .onChange(of: nav.expanded) { e in showColour = e == bulb.id }
        .opacity(bulb.reachable ? 1 : 0.55)
        .revealFlash(BulbRow.revealKey(bulb.mac))
        .id(BulbRow.revealKey(bulb.mac))
    }

    /// The key a link uses to land on this bulb's row in the Home tab.
    static func revealKey(_ mac: String) -> String { "bulb-" + mac }

    /// A hue strip for any colour, eight quick swatches, and a way back to white.
    /// It stays inside the panel: the system colour window would take focus and
    /// close the popover mid-pick.
    private var colourRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: $hue, in: 0...1, onEditingChanged: { e in
                if !e { lights.set(bulb, ["rgb=\(hueHex(hue))"]) }
            })
            .sbControlSize(.mini)
            // the wheel walks the colour wheel, a twenty-fourth a notch, round and round
            .scrollSteps("bulb-hue-" + bulb.mac, inContent: true, stepper: .slider()) { by in
                hue = (hue - Double(by) / 24).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
                lights.set(bulb, ["rgb=\(hueHex(hue))"])
            }
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
                            .frame(width: si(14), height: si(14))
                            .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain).help(s.1)
                }
                Spacer()
                Button("White") { lights.set(bulb, ["temp=\(bulb.temp ?? 2700)"]) }
                    .sbControlSize(.mini)
                    .help("Back to warm or cool white")
            }
        }
    }

    /// Edit the name in the row itself. A separate alert window would close the
    /// panel (it is transient) and could lose the typing.
    private func startRename() {
        draftName = bulb.name
        renaming = true
        // A menu bar app only takes keystrokes once it is the active app.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRename(save: Bool) {
        guard renaming else { return }
        renaming = false
        if save { lights.rename(bulb, to: draftName) }
    }
}
