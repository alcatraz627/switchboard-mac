// Pointer.swift
// The input grammar every surface shares, beyond the left click:
//   - middle click opens a thing in its fuller home (a bulb in the Home tab, a
//     session in Chrome, a badge's tab in the panel);
//   - a link inside the app lands on the thing itself and flashes it once, so
//     the eye never has to search after a jump.
// Places that take a middle click register where they sit, as scroll targets
// do (ScrollSteps.swift); one watcher per window finds the place under the pointer.

import AppKit
import SwiftUI

/// Places that take a middle click, by name, in the window space they are drawn in.
final class MiddleClickTargets {
    static let shared = MiddleClickTargets()
    struct Target { var frame: CGRect; var space: String; var act: () -> Void }
    private(set) var targets: [String: Target] = [:]

    func set(_ id: String, frame: CGRect, space: String, act: @escaping () -> Void) {
        targets[id] = Target(frame: frame, space: space, act: act)
    }
    func remove(_ id: String) { targets[id] = nil }

    /// The place under a point in a space; the smallest wins, so a chip inside a row beats the row.
    func target(in space: String, at p: CGPoint) -> String? {
        targets.filter { $0.value.space == space && $0.value.frame.contains(p) }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?.key
    }

    /// Runs the place under a middle click in a window, if any; true when one took it.
    @discardableResult
    func handle(_ e: NSEvent, in view: NSView, space: String) -> Bool {
        guard e.buttonNumber == 2 else { return false }
        let p = view.convert(e.locationInWindow, from: nil)
        let top = CGPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y)
        guard let id = target(in: space, at: top), let t = targets[id] else { return false }
        t.act()
        return true
    }
}

extension View {
    /// Makes this view answer a middle click, in the named window space it is drawn in.
    func onMiddleClick(_ id: String, space: String, _ act: @escaping () -> Void) -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named(space))
            Color.clear
                .onAppear { MiddleClickTargets.shared.set(id, frame: f, space: space, act: act) }
                .onChange(of: f) { nf in MiddleClickTargets.shared.set(id, frame: nf, space: space, act: act) }
                .onDisappear { MiddleClickTargets.shared.remove(id) }
        })
    }
}

/// Where the next jump lands: the row to scroll to and flash, by its key.
final class Reveal: ObservableObject {
    static let shared = Reveal()
    /// The row being revealed and when; a row flashes while this is fresh.
    @Published private(set) var key: String?
    private(set) var at = Date.distantPast
    /// How long a revealed row keeps its flash.
    static let flashFor: TimeInterval = 1.6

    func show(_ key: String) {
        self.key = key
        at = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashFor) { [weak self] in
            if let self, Date().timeIntervalSince(self.at) >= Self.flashFor { self.key = nil }
        }
    }
}

/// Two soft pulses of the accent colour around a row that a link just landed on.
struct RevealFlash: ViewModifier {
    let key: String?
    @ObservedObject private var reveal = Reveal.shared
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(lit ? 0.18 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(lit ? 0.7 : 0), lineWidth: 1.5))
                    .allowsHitTesting(false)
            )
            .onChange(of: reveal.key) { k in
                guard let key, k == key else { return }
                pulse()
            }
            .onAppear {
                // a row drawn after the jump (a tab that had to open first) still gets its flash
                if let key, reveal.key == key { pulse() }
            }
    }

    private func pulse() {
        withAnimation(.easeOut(duration: 0.18)) { lit = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.easeIn(duration: 0.25)) { lit = false } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(.easeOut(duration: 0.18)) { lit = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { withAnimation(.easeIn(duration: 0.4)) { lit = false } }
    }
}

extension View {
    /// Flashes this row when a link inside the app lands on it.
    func revealFlash(_ key: String?) -> some View { modifier(RevealFlash(key: key)) }
}

/// The rules of the grammar without a mouse.
func probePointer() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let t = MiddleClickTargets()
    var hit = ""
    t.set("row", frame: CGRect(x: 0, y: 0, width: 300, height: 30), space: "card") { hit = "row" }
    t.set("chip", frame: CGRect(x: 200, y: 5, width: 60, height: 20), space: "card") { hit = "chip" }
    t.set("other", frame: CGRect(x: 0, y: 0, width: 300, height: 30), space: "panel") { hit = "other" }
    check("a middle click finds the place under it", t.target(in: "card", at: CGPoint(x: 10, y: 10)) == "row")
    check("a chip inside a row wins over the row", t.target(in: "card", at: CGPoint(x: 210, y: 10)) == "chip")
    check("a place in another window does not catch it", t.target(in: "card", at: CGPoint(x: 10, y: 40)) == nil)
    t.targets["row"]?.act()
    check("its action runs", hit == "row", hit)
    let r = Reveal()
    r.show("bulb-1")
    check("a reveal names the row it lands on", r.key == "bulb-1")

    // Hub links: stay in Switchboard's window unless asked for the browser.
    let page = URL(string: "http://127.0.0.1:5400/s/abc")!, web = URL(string: "https://github.com/x")!
    check("a hub link stays in the window", !TranscriptNav.opensInBrowser(page, button: 0, command: false, newWindow: false, link: true))
    check("a middle click on a hub link opens the browser", TranscriptNav.opensInBrowser(page, button: 2, command: false, newWindow: false, link: true))
    check("a Command-click does too", TranscriptNav.opensInBrowser(page, button: 0, command: true, newWindow: false, link: true))
    check("a link outside the hub opens the browser", TranscriptNav.opensInBrowser(web, button: 0, command: false, newWindow: false, link: true))
    check("the hub page's own loads stay put", !TranscriptNav.opensInBrowser(page, button: 0, command: false, newWindow: false, link: false))
    check("a hub page is told apart from the rest", TranscriptWindow.isHub(page) && !TranscriptWindow.isHub(web))

    // Bulbs: a row while on and for two hours after, then a chip.
    let now = Date(timeIntervalSince1970: 100_000)
    var b = Bulb(["ip": "10.0.0.2", "mac": "aa", "reachable": true, "on": false])!
    check("a bulb off for an hour stays a row", LightsStore.keepsRow(b, lastOn: now.addingTimeInterval(-3600), now: now))
    check("a bulb off for three hours becomes a chip", !LightsStore.keepsRow(b, lastOn: now.addingTimeInterval(-3 * 3600), now: now))
    check("a bulb never seen on is a chip", !LightsStore.keepsRow(b, lastOn: nil, now: now))
    b.on = true
    check("a bulb that is on is a row", LightsStore.keepsRow(b, lastOn: nil, now: now))
    return lines
}
