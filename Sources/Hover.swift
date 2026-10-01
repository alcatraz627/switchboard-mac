// Hover.swift
// The hover preview: a small card under the menu bar icon while the pointer
// rests on it, carrying only what the owner chose in Settings (limits, what
// waits, problems, timers, services). Everything shown is already in memory
// except the Claude limits, which are one small file read per hover.

import AppKit
import SwiftUI

/// One line of the preview: a usage bar, or a short sentence with a symbol.
enum HoverLine: Identifiable {
    /// `icon` says whose bar it is (Claude, Codex) so the label can stay a bare span.
    case bar(label: String, pct: Int, color: Color, resets: String, icon: String? = nil)
    case note(icon: String, text: String, tint: Color)

    var id: String {
        switch self {
        case .bar(let l, _, _, _, let icon): return "bar-" + (icon ?? "") + l
        case .note(let i, let t, _): return i + t
        }
    }
}

struct HoverPreview: View {
    let lines: [HoverLine]

    var body: some View {
        HoverLinesView(lines: lines)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 300, alignment: .leading)
            .background(GlassBackground())
    }
}

/// The preview's lines on their own, so the quick pages can show them too.
struct HoverLinesView: View {
    let lines: [HoverLine]
    var labelWidth: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                switch line {
                case .bar(let label, let pct, let color, let resets, let icon):
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                            Text(label).font(.system(size: 11, weight: .medium))
                        }
                        .frame(width: labelWidth, alignment: .leading)
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
    private let state: QuickState
    /// Fills the Now page (its lines and status chips) from what is in memory.
    private let refresh: () -> Void
    private let panelOpen: () -> Bool
    private var closeWork: DispatchWorkItem?
    private var poll: Timer?
    private var scrollWatch: Any?
    private var keyWatch: Any?
    private var cycle = QuickCycle()
    private var inside = false
    /// How long the card stays after the pointer leaves, so a chip can still be reached.
    static let linger: TimeInterval = 3

    init(button: NSStatusBarButton, state: QuickState, card: AnyView,
         refresh: @escaping () -> Void, panelOpen: @escaping () -> Bool) {
        self.button = button
        self.state = state
        self.refresh = refresh
        self.panelOpen = panelOpen
        super.init()
        popover.behavior = .applicationDefined   // it follows the pointer, not clicks
        popover.animates = false
        popover.appearance = NSAppearance(named: .vibrantDark)
        let host = NSHostingController(rootView: card)
        host.sizingOptions = [.preferredContentSize]   // the card resizes as pages change
        popover.contentViewController = host
        // A tracking area on a status item never reaches a non-view owner, so the
        // pointer is checked against the icon's frame five times a second instead.
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.check() }
        // Lets macOS batch this wake-up with others; a hover a tenth of a second late is unnoticeable.
        poll?.tolerance = 0.1
        // Scrolling over the icon or the card's title bar turns the page; over the content it does not.
        scrollWatch = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, QuickCycle.turnsPage(at: self.spot(of: e), headerBottom: self.state.headerBottom) else { return e }
            self.scrolled(e)
            return e
        }
        // Number keys pick a page while the card has the keyboard and no field is being typed in.
        keyWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.popover.isShown, let w = self.cardWindow, e.window === w,
                  e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let p = QuickCycle.page(forKey: e.charactersIgnoringModifiers ?? "", in: self.state.pages,
                                          typing: w.firstResponder is NSTextView) else { return e }
            self.cycle.show(p)
            self.state.page = self.cycle.page
            return nil
        }
    }

    deinit { [scrollWatch, keyWatch].compactMap { $0 }.forEach(NSEvent.removeMonitor) }

    private var cardWindow: NSWindow? { popover.contentViewController?.view.window }

    /// Where a scroll landed: on the icon, on the card (measured from its top), or elsewhere.
    private func spot(of e: NSEvent) -> QuickCycle.Spot {
        if let b = button, e.window === b.window { return .icon }
        guard popover.isShown, let v = popover.contentViewController?.view, e.window === v.window else { return .elsewhere }
        let p = v.convert(e.locationInWindow, from: nil)
        return .card(fromTop: v.isFlipped ? p.y : v.bounds.height - p.y)
    }

    private func scrolled(_ e: NSEvent) {
        guard !panelOpen() else { return }
        cycle.pages = state.pages
        cycle.show(state.page)   // a pill clicked on the card moved the page
        guard cycle.scroll(delta: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas, phase: .init(e),
                           momentum: !e.momentumPhase.isEmpty, at: e.timestamp) else { return }
        closeWork?.cancel()
        if !popover.isShown { refresh(); present() }
        state.page = cycle.page
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
        guard !panelOpen(), !popover.isShown else { return }
        // a fresh hover reopens on the page the last one showed, or the first if that page is gone
        cycle.pages = state.pages
        cycle.show(state.page)
        cycle.forgetGesture()
        state.page = cycle.page
        refresh()
        present()
    }

    private func present() {
        guard let b = button, let host = popover.contentViewController else { return }
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    private func exited() {
        let work = DispatchWorkItem { [weak self] in self?.popover.performClose(nil) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    /// Closes it at once, as when the panel opens.
    func hide() { closeWork?.cancel(); popover.performClose(nil) }
}

/// Draws the preview offscreen in dark or light, for checking without a pointer.
/// `dark` is ignored: the live card is always vibrant dark, so the snapshot is too.
func snapshotHover(_ lines: [HoverLine], to path: String, dark: Bool) -> Bool {
    snapshotCard(AnyView(HoverPreview(lines: lines)), to: path)
}

/// Draws any hover card offscreen, the way it looks under the menu bar.
func snapshotCard(_ card: AnyView, to path: String) -> Bool {
    let appearance = NSAppearance(named: .vibrantDark)!
    let host = NSHostingView(rootView: card.background(Color(nsColor: .windowBackgroundColor)))
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
