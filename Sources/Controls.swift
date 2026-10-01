// Controls.swift
// The Controls tab: sound output, display brightness, Wi-Fi and Bluetooth in
// one place, so the separate menu bar items for each can be hidden. Every
// control talks to macOS directly (CoreAudio, DisplayServices, CoreWLAN,
// IOBluetooth); nothing needs installing.

import AppKit
import AudioToolbox
import CoreAudio
import CoreLocation
import CoreWLAN
import IOBluetooth
import SwiftUI

// ── Sound: CoreAudio ────────────────────────────────────────────────────────

enum AudioOut {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Devices that can play sound, by name.
    static func outputs() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
            var nameAddr = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &ns, &name) == noErr, let n = name else { return nil }
            return Device(id: id, name: n.takeRetainedValue() as String)
        }
    }

    static func defaultOutput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var v = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &v) == noErr
    }

    /// 0...1, or nil for a device whose volume macOS cannot set (HDMI, some docks).
    static func volume(_ id: AudioDeviceID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var v = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func muted(_ id: AudioDeviceID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    static func setMuted(_ id: AudioDeviceID, _ on: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var v: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}

// ── Display: DisplayServices (the built-in screen only) ────────────────────

enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    // A private framework: fine for a personal app, would block the App Store.
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0...1, or nil with the lid closed or no built-in screen.
    static func get() -> Float? {
        guard let d = builtinDisplay(), let f = getFn else { return nil }
        var v: Float = 0
        return f(d, &v) == 0 ? v : nil
    }

    static func set(_ value: Float) -> Bool {
        guard let d = builtinDisplay(), let f = setFn else { return false }
        return f(d, min(max(value, 0.02), 1)) == 0
    }
}

// ── Bluetooth: IOBluetooth ──────────────────────────────────────────────────

// Exported by IOBluetooth and used by macOS's own Bluetooth menu; not in its headers.
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState") private func btGetPower() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState") private func btSetPower(_ state: Int32)

struct BTDevice: Identifiable, Equatable {
    let id: String   // address
    let name: String
    let connected: Bool
}

// ── The store ───────────────────────────────────────────────────────────────

final class ControlsStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var outputs: [AudioOut.Device] = []
    @Published var output: AudioDeviceID?
    @Published var volume: Float?
    @Published var muted: Bool?
    @Published var brightness: Float?
    @Published var wifiOn: Bool?
    @Published var ssid: String?
    @Published var locationAllowed = false
    @Published var btOn: Bool?
    @Published var btDevices: [BTDevice] = []
    @Published var btListed = false
    /// What did not stick, by control, in plain words.
    @Published var failures: [String: String] = [:]
    @Published var busy: Set<String> = []
    private var location: CLLocationManager?

    /// Read everything. Paired Bluetooth devices ask macOS for Bluetooth
    /// access the first time, so they are read only when the tab is shown.
    func load(devices: Bool = true) {
        outputs = AudioOut.outputs()
        output = AudioOut.defaultOutput()
        volume = output.flatMap(AudioOut.volume)
        muted = output.flatMap(AudioOut.muted)
        brightness = Brightness.get()
        let wifi = CWWiFiClient.shared().interface()
        wifiOn = wifi?.powerOn()
        ssid = wifi?.ssid()
        locationAllowed = [.authorizedAlways, .authorized].contains(CLLocationManager().authorizationStatus)
        btOn = btGetPower() != 0
        if devices, !Visibility.sectionHidden("controls", "Bluetooth") { loadBluetoothDevices() }
    }

    func loadBluetoothDevices() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        btDevices = paired.map { BTDevice(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Unnamed", connected: $0.isConnected()) }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
        btListed = true
    }

    private func fail(_ key: String, _ msg: String) {
        failures[key] = msg
        dwarn("controls \(key): \(msg)")
    }

    func pickOutput(_ id: AudioDeviceID) {
        failures["output"] = nil
        guard AudioOut.setDefaultOutput(id) else { return fail("output", "macOS did not switch the output.") }
        load(devices: false)
    }

    func setVolume(_ v: Float) {
        failures["volume"] = nil
        guard let id = output else { return fail("volume", "No sound output is selected.") }
        guard AudioOut.setVolume(id, v) else { return fail("volume", "This output does not take a volume from apps.") }
        volume = AudioOut.volume(id)
    }

    func toggleMute() {
        failures["volume"] = nil
        guard let id = output else { return fail("volume", "No sound output is selected.") }
        guard let m = muted else { return fail("volume", "This output does not report whether it is muted.") }
        guard AudioOut.setMuted(id, !m) else { return fail("volume", "This output cannot be muted from apps.") }
        muted = AudioOut.muted(id)
    }

    func setBrightness(_ v: Float) {
        failures["brightness"] = nil
        guard Brightness.set(v) else { return fail("brightness", "The built-in display did not take the change.") }
        brightness = Brightness.get()
    }

    func setWiFi(_ on: Bool) {
        failures["wifi"] = nil
        guard let wifi = CWWiFiClient.shared().interface() else { return fail("wifi", "This Mac has no Wi-Fi interface to switch.") }
        do {
            try wifi.setPower(on)
        } catch {
            return fail("wifi", "Wi-Fi did not turn \(on ? "on" : "off"): \(error.localizedDescription)")
        }
        // The radio reports its new state a moment after it switches; read it back to know it stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.load(devices: false)
            if self.wifiOn != on { self.fail("wifi", "Wi-Fi is still \(on ? "off" : "on").") }
        }
    }

    func askLocation() {
        let m = CLLocationManager()
        m.delegate = self
        location = m
        NSApp.activate(ignoringOtherApps: true)
        m.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        load(devices: btListed)
    }

    func setBluetooth(_ on: Bool) {
        failures["bluetooth"] = nil
        btSetPower(on ? 1 : 0)
        // The controller takes a moment; read it back to know it stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.btOn = btGetPower() != 0
            if self.btOn != on { self.fail("bluetooth", "Bluetooth is still \(on ? "off" : "on").") }
            if self.btListed { self.loadBluetoothDevices() }
        }
    }

    func toggleDevice(_ d: BTDevice) {
        failures[d.id] = nil
        guard let dev = IOBluetoothDevice(addressString: d.id) else {
            return fail(d.id, "\(d.name) is no longer paired with this Mac.")
        }
        busy.insert(d.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = d.connected ? dev.closeConnection() : dev.openConnection()
            DispatchQueue.main.async {
                self.busy.remove(d.id)
                if r != kIOReturnSuccess {
                    self.fail(d.id, "\(d.name) did not \(d.connected ? "disconnect" : "connect"). Is it on and nearby?")
                }
                self.loadBluetoothDevices()
            }
        }
    }
}

// ── The tab ─────────────────────────────────────────────────────────────────

struct ControlsTabView: View {
    @ObservedObject var controls: ControlsStore
    @State private var volumeDraft: Float?
    @State private var brightDraft: Float?

    var body: some View {
        VStack(alignment: .leading, spacing: SBStyle.gap) {
            // Sound and Display take two rows each: the name with its buttons, then the slider with its level.
            section("Sound") {
                row(icon: controls.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: controls.outputs.first { $0.id == controls.output }?.name ?? "No output",
                    caption: controls.volume == nil ? "volume set on the device" : nil) {
                    if controls.muted != nil {
                        Button { controls.toggleMute() } label: {
                            Image(systemName: controls.muted == true ? "speaker.slash" : "speaker.wave.1")
                                .font(.system(size: 12)).frame(width: 18, height: 16)
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(controls.muted == true ? "Unmute" : "Mute")
                    }
                    outputMenu
                }
                if let v = controls.volume {
                    let shown = volumeDraft ?? v
                    slider("controls.volume", value: shown, level: controls.muted == true ? "muted" : "\(Int((shown * 100).rounded()))%",
                           set: { volumeDraft = $0 }, commit: { controls.setVolume($0); volumeDraft = nil })
                }
                failure("output"); failure("volume")
            }
            if let b = controls.brightness {
                section("Display") {
                    row(icon: "sun.max.fill", title: "Built-in display", caption: nil) { EmptyView() }
                    let shown = brightDraft ?? b
                    slider("controls.brightness", value: shown, level: "\(Int((shown * 100).rounded()))%",
                           set: { brightDraft = $0; controls.setBrightness($0) }, commit: { _ in brightDraft = nil })
                    failure("brightness")
                }
            }
            if let on = controls.wifiOn {
                section("Wi-Fi") {
                    row(icon: on ? "wifi" : "wifi.slash", title: "Wi-Fi",
                        caption: !on ? "off" : controls.ssid ?? (controls.locationAllowed ? "not connected" : "connected · name hidden by macOS"),
                        captionIsName: on && controls.ssid != nil) {
                        if on && controls.ssid == nil && !controls.locationAllowed {
                            Button("Show name") { controls.askLocation() }.buttonStyle(.link).font(SBStyle.caption)
                                .help("macOS shows the network name only to apps with Location access")
                        }
                        Toggle("", isOn: Binding(get: { on }, set: { new in
                            if !new && !confirm("Turn Wi-Fi off?", "Everything on this Mac that uses the network loses it, including remote sessions.") { return }
                            controls.setWiFi(new)
                        })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    failure("wifi")
                }
            }
            if let on = controls.btOn {
                section("Bluetooth") {
                    row(icon: "dot.radiowaves.left.and.right", title: "Bluetooth",
                        caption: !on ? "off" : controls.btListed ? "\(controls.btDevices.filter(\.connected).count) connected" : "on") {
                        Toggle("", isOn: Binding(get: { on }, set: { new in
                            if !new && !confirm("Turn Bluetooth off?", "A Bluetooth keyboard, mouse or headphones disconnect at once.") { return }
                            controls.setBluetooth(new)
                        })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    failure("bluetooth")
                    if on {
                        ForEach(controls.btDevices) { d in
                            Divider().padding(.leading, SBStyle.rowH + 26)
                            row(icon: d.connected ? "checkmark.circle.fill" : "circle", title: d.name,
                                caption: d.connected ? "connected" : "paired", indent: 14) {
                                if controls.busy.contains(d.id) { PendingMark(since: Date()) }
                                Button { controls.toggleDevice(d) } label: {
                                    Image(systemName: d.connected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                                        .font(.system(size: 12)).frame(width: 18, height: 16)
                                }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help(d.connected ? "Disconnect" : "Connect")
                                .disabled(controls.busy.contains(d.id))
                            }
                            failure(d.id)
                        }
                    }
                }
            }
        }
        .padding(SBStyle.gap)
    }

    // ── Pieces ──

    @ViewBuilder private func section<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        if !Visibility.sectionHidden("controls", name) {
            VStack(alignment: .leading, spacing: 5) {
                GroupHeader(name: name)
                Card { VStack(alignment: .leading, spacing: 0) { content() } }
            }
        }
    }

    /// A row's title is always a name (a device, a network), so it stays on
    /// one line and gives up its middle when it does not fit.
    private func row<C: View>(icon: String, title: String, caption: String?, captionIsName: Bool = false, indent: CGFloat = 0,
                              @ViewBuilder trailing: () -> C) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(SBStyle.label).nameFit(title)
                if let caption {
                    if captionIsName {
                        Text(caption).font(SBStyle.caption).foregroundStyle(.secondary).nameFit(caption)
                    } else {
                        Text(caption).font(SBStyle.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.leading, SBStyle.rowH + indent).padding(.trailing, SBStyle.rowH).padding(.vertical, SBStyle.rowV + 1)
    }

    /// The level slider: scrolling over it moves it 5% a notch, and its level reads at the end.
    private func slider(_ id: String, value: Float, level: String,
                        set: @escaping (Float) -> Void, commit: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1,
                   onEditingChanged: { editing in if !editing { commit(value) } })
                .controlSize(.mini)
            Text(level).font(SBStyle.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.leading, SBStyle.rowH + 26).padding(.trailing, SBStyle.rowH).padding(.bottom, SBStyle.rowV + 2)
        // up raises it, down lowers it, the way a volume wheel turns
        .scrollSteps(id, inContent: true, stepper: .slider()) { by in
            let v = sliderStep(value, by: -by)
            set(v); commit(v)
        }
    }

    private var outputMenu: some View {
        Menu {
            ForEach(controls.outputs) { d in
                Button(d.name + (d.id == controls.output ? "  ✓" : "")) { controls.pickOutput(d.id) }
            }
        } label: {
            Image(systemName: "hifispeaker.2").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Choose the output")
    }

    @ViewBuilder private func failure(_ key: String) -> some View {
        if let f = controls.failures[key] {
            RowFailure(message: f, dismiss: { controls.failures[key] = nil })
        }
    }

    private func confirm(_ title: String, _ detail: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.addButton(withTitle: "Turn off")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
}

// ── Headless probe ──────────────────────────────────────────────────────────

/// Writes each control back to the value it already has (and mutes, then
/// unmutes), reading every one back, so the write paths are exercised with
/// nothing the owner would notice. Wi-Fi and Bluetooth are left alone.
func probeControls() -> String {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "ok  " : "FAIL") \(name)") }
    if let out = AudioOut.defaultOutput() {
        if let v = AudioOut.volume(out) {
            check("volume write-back (\(Int(v * 100))%)", AudioOut.setVolume(out, v) && abs((AudioOut.volume(out) ?? -1) - v) < 0.02)
        } else { lines.append("skip volume: this output takes no app volume") }
        if let m = AudioOut.muted(out) {
            let flipped = AudioOut.setMuted(out, !m) && AudioOut.muted(out) == !m
            let restored = AudioOut.setMuted(out, m) && AudioOut.muted(out) == m
            check("mute flip and restore", flipped && restored)
        }
    } else { lines.append("FAIL no default output") }
    if let b = Brightness.get() {
        check("brightness write-back (\(Int(b * 100))%)", Brightness.set(b) && abs((Brightness.get() ?? -1) - b) < 0.02)
    } else { lines.append("skip brightness: no built-in display") }
    lines.append("wifi power readable: \(CWWiFiClient.shared().interface()?.powerOn() != nil)")
    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}
