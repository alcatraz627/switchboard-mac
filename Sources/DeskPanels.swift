// DeskPanels.swift
// Desk panels: any hover page (Sessions, Limits, Bulbs…) or any panel tab
// pinned as a small window on the desktop, live and clickable, the way a
// widget would be if widgets could hold sliders and lists. Each sits on the
// desktop layer by default (or above other windows, if chosen), shows on every
// Space, and comes back where it was after a restart.

import AppKit
import SwiftUI

/// One pinned panel: what it shows and where it sits.
struct DeskItem: Codable, Equatable {
    enum Kind: String, Codable { case page, tab }
    var kind: Kind
    var id: String
    var frame: [Double]? = nil
    var onTop = false

    var key: String { kind.rawValue + "-" + id }
    /// The window space its card draws in, so its clicks and wheel steps stay its own.
    var space: String { "desk-" + key }
}

final class DeskPanels: NSObject, NSWindowDelegate {
    static let shared = DeskPanels()
    static let saveKey = "switchboard.deskPanels"
    /// Draws an item's content; set by the menu-bar controller, which owns the stores.
    var content: (DeskItem) -> AnyView? = { _ in nil }
    /// The name an item is shown under.
    var title: (DeskItem) -> String = { $0.id }
    private(set) var items: [DeskItem] = DeskPanels.load()
    private var windows: [String: NSPanel] = [:]
    private var watches: [Any] = []

    static func load() -> [DeskItem] {
        guard let d = UserDefaults.standard.data(forKey: saveKey) else { return [] }
        return (try? JSONDecoder().decode([DeskItem].self, from: d)) ?? []
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.saveKey) }
    }

    func isPinned(_ kind: DeskItem.Kind, _ id: String) -> Bool { items.contains { $0.kind == kind && $0.id == id } }

    /// Pins a page or tab, or brings its panel forward when it is already pinned.
    func pin(_ kind: DeskItem.Kind, _ id: String) {
        if let w = windows[kind.rawValue + "-" + id] { w.orderFrontRegardless(); return }
        let item = DeskItem(kind: kind, id: id)
        items.append(item)
        save()
        open(item)
    }

    func unpin(_ key: String) {
        items.removeAll { $0.key == key }
        save()
        windows[key]?.close()
        windows[key] = nil
    }

    /// Opens every saved panel; called once at launch.
    func restore() {
        watchEvents()
        items.forEach(open)
    }

    private func open(_ item: DeskItem) {
        guard windows[item.key] == nil, let body = content(item) else { return }
        watchEvents()
        let host = NSHostingView(rootView: ScaledRoot {
            DeskFrame(item: item, title: self.title(item), toggleTop: { [weak self] in self?.toggleTop(item.key) },
                      close: { [weak self] in self?.unpin(item.key) }) { body }
        })
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = host
        p.delegate = self
        p.identifier = NSUserInterfaceItemIdentifier(item.key)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        Self.applyLevel(p, onTop: item.onTop)
        if let f = item.frame, f.count == 4 { p.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: false) }
        else { p.center() }
        windows[item.key] = p
        p.orderFrontRegardless()
    }

    /// On the desktop (below every window) or above other windows.
    static func applyLevel(_ p: NSPanel, onTop: Bool) {
        p.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func toggleTop(_ key: String) {
        guard let i = items.firstIndex(where: { $0.key == key }), let p = windows[key] else { return }
        items[i].onTop.toggle()
        save()
        Self.applyLevel(p, onTop: items[i].onTop)
        p.orderFrontRegardless()
    }

    // keep each panel's place when it is moved or resized
    func windowDidMove(_ n: Notification) { remember(n) }
    func windowDidEndLiveResize(_ n: Notification) { remember(n) }
    private func remember(_ n: Notification) {
        guard let w = n.object as? NSWindow, let key = w.identifier?.rawValue,
              let i = items.firstIndex(where: { $0.key == key }) else { return }
        let f = w.frame
        items[i].frame = [f.origin.x, f.origin.y, f.width, f.height]
        save()
    }
    func windowWillClose(_ n: Notification) {
        // the title bar's close button unpins, the same as the panel's own ✕
        guard let w = n.object as? NSWindow, let key = w.identifier?.rawValue, windows[key] != nil else { return }
        windows[key] = nil
        items.removeAll { $0.key == key }
        save()
    }

    /// The same wheel and middle-click grammar as the hover card, inside each desk panel.
    private func watchEvents() {
        guard watches.isEmpty else { return }
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, let (v, space) = self.deskView(of: e) else { return e }
            let p = v.convert(e.locationInWindow, from: nil)
            return ScrollTargets.forSpace(space).handle(e, at: CGPoint(x: p.x, y: v.isFlipped ? p.y : v.bounds.height - p.y)) ? nil : e
        }) { watches.append(s) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] e in
            guard let self, let (v, space) = self.deskView(of: e) else { return e }
            return MiddleClickTargets.shared.handle(e, in: v, space: space) ? nil : e
        }) { watches.append(m) }
    }
    private func deskView(of e: NSEvent) -> (NSView, String)? {
        guard let w = e.window, let key = w.identifier?.rawValue, windows[key] === w, let v = w.contentView,
              let item = items.first(where: { $0.key == key }) else { return nil }
        return (v, item.space)
    }
}

/// A desk panel's frame: a slim title row (name, float or desk, close) over the content.
struct DeskFrame<Content: View>: View {
    let item: DeskItem
    let title: String
    let toggleTop: () -> Void
    let close: () -> Void
    @ViewBuilder let content: Content
    @State private var onTop: Bool

    init(item: DeskItem, title: String, toggleTop: @escaping () -> Void, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.item = item; self.title = title; self.toggleTop = toggleTop; self.close = close
        self.content = content()
        _onTop = State(initialValue: item.onTop)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.sb(10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { onTop.toggle(); toggleTop() } label: {
                    Image(systemName: onTop ? "square.stack.3d.up.fill" : "square.stack.3d.down.right").font(.sbIcon(10))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(onTop ? "Above other windows; click to keep it on the desktop" : "On the desktop; click to keep it above other windows")
                Button(action: close) { Image(systemName: "xmark").font(.sbIcon(9.5, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Unpin from the desktop")
            }
            .padding(.horizontal, sc(10)).padding(.top, sc(24)).padding(.bottom, sc(2))
            content
        }
        .background(GlassBackground())
        .environment(\.cardSpace, item.space)
    }
}

/// A panel tab on its own: its sections, scrolling, without the tab bar.
struct DeskTab: View {
    let concern: SwitchboardConcern
    var body: some View {
        ScrollView(.vertical) { concern.content.padding(.bottom, sc(8)) }
            .frame(width: PT.width, height: min(PT.maxHeight, sw(520)))
            .coordinateSpace(name: ScrollTargets.space)
    }
}

/// The rules for saving and naming desk panels, without opening one.
func probeDesk() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let a = DeskItem(kind: .page, id: "sessions", frame: [10, 20, 300, 200], onTop: true)
    let back = (try? JSONDecoder().decode([DeskItem].self, from: JSONEncoder().encode([a]))) ?? []
    check("a pinned panel keeps what it shows, where it was and its layer", back == [a])
    check("each panel draws in a window space of its own", a.space == "desk-page-sessions" && a.space != ScrollTargets.cardSpace)
    check("a page and a tab of the same name are different panels",
          DeskItem(kind: .page, id: "notes").key != DeskItem(kind: .tab, id: "notes").key)
    return lines
}
