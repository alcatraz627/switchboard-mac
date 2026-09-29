// Hover.swift
// The hover preview: a small card under the menu bar icon while the pointer
// rests on it, carrying only what the owner chose in Settings (limits, what
// waits, problems, timers, services). Everything shown is already in memory;
// hovering never starts a read.

import AppKit
import SwiftUI

/// One line of the preview: a usage bar, or a short sentence with a symbol.
enum HoverLine: Identifiable {
    case bar(label: String, pct: Int, color: Color, resets: String)
    case note(icon: String, text: String, tint: Color)

    var id: String {
        switch self {
        case .bar(let l, _, _, _): return "bar-" + l
        case .note(let i, let t, _): return i + t
        }
    }
}

struct HoverPreview: View {
    let lines: [HoverLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                switch line {
                case .bar(let label, let pct, let color, let resets):
                    HStack(spacing: 8) {
                        Text(label).font(.system(size: 11, weight: .medium)).frame(width: 34, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1))
                                Capsule().fill(color).frame(width: max(3, g.size.width * CGFloat(min(pct, 100)) / 100))
                            }
                        }
                        .frame(height: 6)
                        Text("\(pct)%").font(.system(size: 11, weight: .semibold).monospacedDigit()).frame(width: 34, alignment: .trailing)
                        Text(resets).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                    }
                case .note(let icon, let text, let tint):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint).frame(width: 14)
                        Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background(GlassBackground())
    }
}

/// A see-through blur behind the card, like the HUDs macOS draws.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Watches the pointer over the status item and shows the preview while it
/// rests there, unless the panel itself is open or there is nothing to say.
final class HoverPeek: NSObject {
    private weak var button: NSStatusBarButton?
    private let popover = NSPopover()
    private let lines: () -> [HoverLine]
    private let panelOpen: () -> Bool
    private var closeWork: DispatchWorkItem?
    private var poll: Timer?
    private var inside = false

    init(button: NSStatusBarButton, lines: @escaping () -> [HoverLine], panelOpen: @escaping () -> Bool) {
        self.button = button
        self.lines = lines
        self.panelOpen = panelOpen
        super.init()
        popover.behavior = .applicationDefined   // it follows the pointer, not clicks
        popover.animates = false
        popover.appearance = NSAppearance(named: .vibrantDark)
        // A tracking area on a status item never reaches a non-view owner, so the
        // pointer is checked against the icon's frame five times a second instead.
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        guard let b = button, let win = b.window else { return }
        let frame = win.convertToScreen(b.convert(b.bounds, to: nil))
        // The card counts as inside too, so moving onto it keeps it open.
        let card = popover.isShown ? popover.contentViewController?.view.window?.frame : nil
        let now = frame.contains(NSEvent.mouseLocation) || (card?.insetBy(dx: -4, dy: -8).contains(NSEvent.mouseLocation) ?? false)
        guard now != inside else { return }
        inside = now
        if now { entered() } else { exited() }
    }

    private func entered() {
        closeWork?.cancel()
        guard let b = button, !panelOpen(), !popover.isShown else { return }
        let l = lines()
        guard !l.isEmpty else { return }
        let host = NSHostingController(rootView: HoverPreview(lines: l))
        host.view.layoutSubtreeIfNeeded()
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    private func exited() {
        let work = DispatchWorkItem { [weak self] in self?.popover.performClose(nil) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Closes it at once, as when the panel opens.
    func hide() { closeWork?.cancel(); popover.performClose(nil) }
}

/// Draws the preview offscreen in dark or light, for checking without a pointer.
func snapshotHover(_ lines: [HoverLine], to path: String, dark: Bool) -> Bool {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let host = NSHostingView(rootView: HoverPreview(lines: lines).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = appearance
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

/// The small yellow dot on the menu bar icon while something waits on the owner.
final class IconDot {
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))

    init(on button: NSStatusBarButton) {
        dot.wantsLayer = true
        dot.layer?.backgroundColor = menuYellow.cgColor
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        button.addSubview(dot)
        dot.frame.origin = NSPoint(x: button.bounds.width - 8, y: button.bounds.height - 8)
        dot.autoresizingMask = [.minXMargin, .minYMargin]
    }

    func show(_ on: Bool, color: NSColor) {
        dot.isHidden = !on
        dot.layer?.backgroundColor = color.cgColor
    }
}
