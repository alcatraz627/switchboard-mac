// DeskPanels.swift
// Desk panels: any hover page (Sessions, Limits, Bulbs…) or any panel tab
// pinned as a small window of its own, live and clickable, the way a widget
// would be if widgets could hold sliders and lists. Each behaves like any other
// window (a click brings it forward, another window can cover it) or stays above
// every window, if chosen; it folds to its title row; several can share one
// window as stacked cards; and each comes back where it was after a restart.

import AppKit
import SwiftUI

/// One pinned panel, or a window of several: what it shows and where it sits.
struct DeskItem: Codable, Equatable {
    enum Kind: String, Codable { case page, tab, stack }
    var kind: Kind
    var id: String
    var frame: [Double]? = nil
    var onTop = false
    /// Folded to its title row.
    var collapsed: Bool? = nil
    /// The panels a stack window holds, top to bottom.
    var children: [DeskItem]? = nil

    var key: String { kind.rawValue + "-" + id }
    /// The window space its card draws in, so its clicks and wheel steps stay its own.
    var space: String { "desk-" + key }
    var isCollapsed: Bool { collapsed ?? false }
}

final class DeskPanels: NSObject, NSWindowDelegate {
    static let shared = DeskPanels()
    /// Probes point this at a list of their own so real panels are never touched.
    static var saveKey = "switchboard.deskPanels"
    /// Draws an item's content; set by the menu-bar controller, which owns the stores.
    var content: (DeskItem) -> AnyView? = { _ in nil }
    /// The name an item is shown under.
    var title: (DeskItem) -> String = { $0.id }
    private(set) var items: [DeskItem] = DeskPanels.load()
    private var windows: [String: NSPanel] = [:]
    /// Each card's own view, by the card's key, so events in a stack find the card under them.
    private var cardHosts: [String: NSView] = [:]
    private var watches: [Any] = []
    /// A panel list of a probe's own, not the app's.
    init(probe: Bool) { super.init(); items = Self.load() }
    override init() { super.init() }
    var openKeys: [String] { Array(windows.keys) }
    func foldCard(_ card: String, in window: String) { toggleFold(card, in: window) }
    func takeCardOut(_ card: String, from stack: String) { takeOut(card, from: stack) }
    func closeAll() { for (_, w) in windows { w.delegate = nil; w.close() }; windows = [:] }

    /// The height of a folded card: its title row.
    static var foldedHeight: CGFloat { sc(30) }

    static func load() -> [DeskItem] {
        guard let d = UserDefaults.standard.data(forKey: saveKey) else { return [] }
        return (try? JSONDecoder().decode([DeskItem].self, from: d)) ?? []
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.saveKey) }
    }

    /// Whether a page or tab is pinned, on its own or inside a stack.
    func isPinned(_ kind: DeskItem.Kind, _ id: String) -> Bool {
        items.contains { ($0.kind == kind && $0.id == id) || ($0.children ?? []).contains { $0.kind == kind && $0.id == id } }
    }

    /// Pins a page or tab, or brings its window forward when it is already pinned.
    func pin(_ kind: DeskItem.Kind, _ id: String) {
        let key = kind.rawValue + "-" + id
        if let w = windows[key] ?? windows.first(where: { k, _ in items.first { $0.key == k }?.children?.contains { $0.key == key } ?? false })?.value {
            w.orderFrontRegardless(); return
        }
        let item = DeskItem(kind: kind, id: id)
        items.append(item)
        save()
        open(item)
    }

    func unpin(_ key: String) {
        forget(key)
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

    /// Every open window, for the "Combine with" menu: its key and its name.
    func others(than key: String) -> [(key: String, title: String)] {
        items.filter { $0.key != key }.map { ($0.key, $0.kind == .stack ? ($0.children ?? []).map(title).joined(separator: " + ") : title($0)) }
    }

    // ── one window ──

    private func makeWindow(_ item: DeskItem, contentView: NSView, size: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        // the panel's own row carries close and layer, so the traffic lights only cost a white strip
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.isOpaque = false
        p.backgroundColor = .clear
        // a click activates the app, so the panel comes forward and can take typing
        p.becomesKeyOnlyIfNeeded = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = contentView
        p.delegate = self
        p.identifier = NSUserInterfaceItemIdentifier(item.key)
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        Self.applyLevel(p, onTop: item.onTop)
        // a saved place on a screen that is no longer connected falls back to the middle of this one
        if let f = item.frame, f.count == 4,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(x: f[0], y: f[1], width: f[2], height: f[3])) }) {
            var r = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if item.isCollapsed { r.origin.y = r.maxY - Self.foldedHeight; r.size.height = Self.foldedHeight }
            p.setFrame(r, display: false)
        } else { p.center() }
        return p
    }

    /// A card: its title row and, unless folded, its content.
    private func cardHost(_ item: DeskItem, in windowKey: String, first: Bool) -> NSHostingView<ScaledRoot<AnyView>>? {
        guard let body = content(item) else { return nil }
        let inStack = windowKey != item.key
        let frame = DeskFrame(item: item, title: title(item), inStack: inStack, first: first,
                              others: { [weak self] in self?.others(than: windowKey) ?? [] },
                              toggleTop: { [weak self] in self?.toggleTop(windowKey) },
                              toggleFold: { [weak self] in self?.toggleFold(item.key, in: windowKey) },
                              combine: { [weak self] target in self?.combine(windowKey, into: target) },
                              takeOut: { [weak self] in self?.takeOut(item.key, from: windowKey) },
                              close: { [weak self] in inStack ? self?.removeCard(item.key, from: windowKey) : self?.unpin(item.key) }) { body }
        let host = NSHostingView(rootView: ScaledRoot { AnyView(frame) })
        cardHosts[item.key] = host
        return host
    }

    private func open(_ item: DeskItem) {
        guard windows[item.key] == nil else { return }
        watchEvents()
        let view: NSView, size: NSSize
        if item.kind == .stack {
            let cards = (item.children ?? []).enumerated().compactMap { i, c in cardHost(c, in: item.key, first: i == 0).map { (c, $0) } }
            guard !cards.isEmpty else { return }
            let stack = NSStackView(views: cards.map(\.1))
            stack.orientation = .vertical
            stack.spacing = 0
            stack.distribution = .fill
            stack.alignment = .width
            for (c, h) in cards {
                // every card spans the window, whatever its own content would hug to
                h.translatesAutoresizingMaskIntoConstraints = false
                h.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                // a folded card keeps its title height; open cards share the rest and grow with the window
                let fit = h.fittingSize.height
                let hc = h.heightAnchor.constraint(equalToConstant: c.isCollapsed ? Self.foldedHeight : max(fit, sc(160)))
                hc.priority = c.isCollapsed ? .required : .defaultLow
                hc.isActive = true
                h.setContentHuggingPriority(c.isCollapsed ? .required : .defaultLow, for: .vertical)
            }
            view = stack
            let w = max(PT.width, cards.map { $0.1.fittingSize.width }.max() ?? PT.width)
            let total = cards.reduce(0) { $0 + ($1.0.isCollapsed ? Self.foldedHeight : max($1.1.fittingSize.height, sc(160))) }
            size = NSSize(width: w, height: min(total, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
        } else {
            guard let host = cardHost(item, in: item.key, first: true) else { return }
            host.frame.size = host.fittingSize
            view = host
            size = item.isCollapsed ? NSSize(width: host.fittingSize.width, height: Self.foldedHeight) : host.fittingSize
        }
        let p = makeWindow(item, contentView: view, size: size)
        windows[item.key] = p
        p.orderFrontRegardless()
    }

    /// Closes a window and draws it again from its item, after the item changed shape.
    private func reopen(_ key: String) {
        if let w = windows[key] { windows[key] = nil; w.delegate = nil; w.close() }
        if let item = items.first(where: { $0.key == key }) { open(item) }
    }

    // ── folding, combining, taking out ──

    /// Folds a card to its title row, or opens it again; a window keeps its top edge.
    private func toggleFold(_ cardKey: String, in windowKey: String) {
        guard let wi = items.firstIndex(where: { $0.key == windowKey }) else { return }
        if windowKey == cardKey {
            items[wi].collapsed = !items[wi].isCollapsed
            save()
            guard let p = windows[windowKey] else { return }
            let f = p.frame
            let open = items[wi].frame.map { CGFloat($0[3]) } ?? max(f.height, sc(320))
            let h = items[wi].isCollapsed ? Self.foldedHeight : max(open, sc(160))
            p.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true, animate: !Motion.reduced)
        } else if var kids = items[wi].children, let ci = kids.firstIndex(where: { $0.key == cardKey }) {
            kids[ci].collapsed = !kids[ci].isCollapsed
            items[wi].children = kids
            save()
            reopen(windowKey)
        }
    }

    /// Puts a window's panels into another window, below what it already holds.
    func combine(_ sourceKey: String, into targetKey: String) {
        guard let si = items.firstIndex(where: { $0.key == sourceKey }), items.contains(where: { $0.key == targetKey }) else { return }
        let source = items[si]
        let moving = source.kind == .stack ? (source.children ?? []) : [source]
        if let w = windows[sourceKey] { windows[sourceKey] = nil; w.delegate = nil; w.close() }
        items.remove(at: si)
        guard let ti = items.firstIndex(where: { $0.key == targetKey }) else { return }
        if items[ti].kind == .stack {
            items[ti].children = (items[ti].children ?? []) + moving.map { var m = $0; m.frame = nil; return m }
            save(); reopen(targetKey)
        } else {
            var target = items[ti]
            let stack = DeskItem(kind: .stack, id: UUID().uuidString.prefix(8).lowercased(), frame: target.frame, onTop: target.onTop,
                                 children: ([target] + moving).map { var m = $0; m.frame = nil; m.onTop = false; return m })
            if let w = windows[targetKey] { windows[targetKey] = nil; w.delegate = nil; w.close() }
            target.frame = nil
            items[ti] = stack
            save(); open(stack)
        }
    }

    /// Lifts one card out of a stack into a window of its own, beside the stack.
    private func takeOut(_ cardKey: String, from stackKey: String) {
        guard let wi = items.firstIndex(where: { $0.key == stackKey }), var kids = items[wi].children,
              let ci = kids.firstIndex(where: { $0.key == cardKey }) else { return }
        var card = kids.remove(at: ci)
        card.collapsed = nil
        if let f = windows[stackKey]?.frame { card.frame = [f.maxX + 12, f.minY, f.width, f.height] }
        items[wi].children = kids
        items.append(card)
        settle(stackKey)
        open(card)
    }

    /// Unpins one card of a stack.
    private func removeCard(_ cardKey: String, from stackKey: String) {
        guard let wi = items.firstIndex(where: { $0.key == stackKey }) else { return }
        forget(cardKey)
        items[wi].children?.removeAll { $0.key == cardKey }
        settle(stackKey)
    }

    /// A stack left with one card becomes that card's own window; with none, it closes.
    private func settle(_ stackKey: String) {
        guard let wi = items.firstIndex(where: { $0.key == stackKey }) else { return }
        let kids = items[wi].children ?? []
        if kids.count >= 2 { save(); reopen(stackKey); return }
        let frame = items[wi].frame, onTop = items[wi].onTop
        if let w = windows[stackKey] { windows[stackKey] = nil; w.delegate = nil; w.close() }
        items.remove(at: wi)
        if var last = kids.first { last.frame = frame; last.onTop = onTop; items.append(last); save(); open(last) } else { save() }
    }

    /// Drops a closed panel's click and wheel places, which its views may not get to remove.
    private func forget(_ key: String) {
        guard let item = items.first(where: { $0.key == key }) ?? items.flatMap({ $0.children ?? [] }).first(where: { $0.key == key }) else { return }
        for i in [item] + (item.children ?? []) {
            MiddleClickTargets.shared.removeSpace(i.space)
            ScrollTargets.forget(i.space)
            cardHosts[i.key] = nil
        }
    }

    /// Among the other windows, or above all of them.
    static func applyLevel(_ p: NSPanel, onTop: Bool) {
        p.level = onTop ? .floating : .normal
    }

    private func toggleTop(_ key: String) {
        guard let i = items.firstIndex(where: { $0.key == key }), let p = windows[key] else { return }
        items[i].onTop.toggle()
        save()
        Self.applyLevel(p, onTop: items[i].onTop)
        p.orderFrontRegardless()
    }

    // keep each window's place when it is moved or resized; a folded window keeps its open height
    func windowDidMove(_ n: Notification) { remember(n) }
    func windowDidEndLiveResize(_ n: Notification) { remember(n) }
    private func remember(_ n: Notification) {
        guard let w = n.object as? NSWindow, let key = w.identifier?.rawValue,
              let i = items.firstIndex(where: { $0.key == key }) else { return }
        let f = w.frame
        if items[i].isCollapsed, let old = items[i].frame, old.count == 4 {
            items[i].frame = [f.origin.x, f.maxY - old[3], f.width, old[3]]
        } else {
            items[i].frame = [f.origin.x, f.origin.y, f.width, f.height]
        }
        save()
    }
    func windowWillClose(_ n: Notification) {
        // the title bar's close button unpins, the same as the panel's own ✕
        guard let w = n.object as? NSWindow, let key = w.identifier?.rawValue, windows[key] != nil else { return }
        forget(key)
        windows[key] = nil
        items.removeAll { $0.key == key }
        save()
    }

    /// The same wheel, middle-click and keys as the panel, inside each card.
    private func watchEvents() {
        guard watches.isEmpty else { return }
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, let (v, card) = self.card(at: e) else { return e }
            let p = v.convert(e.locationInWindow, from: nil)
            return ScrollTargets.forSpace(card.space).handle(e, at: CGPoint(x: p.x, y: v.isFlipped ? p.y : v.bounds.height - p.y)) ? nil : e
        }) { watches.append(s) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] e in
            guard let self, let (v, card) = self.card(at: e) else { return e }
            return MiddleClickTargets.shared.handle(e, in: v, space: card.space) ? nil : e
        }) { watches.append(m) }
        // a pinned tab answers the same keys it does in the panel; in a stack, the card under the pointer does
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, let (_, card) = self.card(at: e, pointer: true), card.kind == .tab else { return e }
            return KeyRouter.handle(e, space: card.space, tab: card.id) ? nil : e
        }) { watches.append(k) }
    }

    /// The card an event belongs to: in a single window its only card; in a stack the
    /// card under the event (or, for keys, under the pointer, else the first tab card).
    private func card(at e: NSEvent, pointer: Bool = false) -> (NSView, DeskItem)? {
        guard let w = e.window, let key = w.identifier?.rawValue, windows[key] === w,
              let item = items.first(where: { $0.key == key }) else { return nil }
        guard item.kind == .stack else { return w.contentView.map { ($0, item) } }
        let kids = item.children ?? []
        let at = pointer ? w.convertPoint(fromScreen: NSEvent.mouseLocation) : e.locationInWindow
        for c in kids {
            guard let h = cardHosts[c.key], h.window === w else { continue }
            if h.convert(h.bounds, to: nil).contains(at) { return (h, c) }
        }
        if pointer, let t = kids.first(where: { $0.kind == .tab }), let h = cardHosts[t.key] { return (h, t) }
        return nil
    }
}

/// A desk card's frame: a slim title row (name, fold, combine, layer, close) over the content.
struct DeskFrame<Content: View>: View {
    let item: DeskItem
    let title: String
    let inStack: Bool
    let first: Bool
    let others: () -> [(key: String, title: String)]
    let toggleTop: () -> Void
    let toggleFold: () -> Void
    let combine: (String) -> Void
    let takeOut: () -> Void
    let close: () -> Void
    @ViewBuilder let content: Content
    @State private var onTop: Bool

    init(item: DeskItem, title: String, inStack: Bool, first: Bool, others: @escaping () -> [(key: String, title: String)],
         toggleTop: @escaping () -> Void, toggleFold: @escaping () -> Void, combine: @escaping (String) -> Void,
         takeOut: @escaping () -> Void, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.item = item; self.title = title; self.inStack = inStack; self.first = first; self.others = others
        self.toggleTop = toggleTop; self.toggleFold = toggleFold; self.combine = combine; self.takeOut = takeOut; self.close = close
        self.content = content()
        _onTop = State(initialValue: item.onTop)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if inStack && !first { Divider() }
            HStack(spacing: 6) {
                // the title row folds the card: a click on the chevron, or a double click anywhere on the row
                Button(action: toggleFold) {
                    Image(systemName: "chevron.right").font(.sbIcon(9, weight: .semibold))
                        .rotationEffect(.degrees(item.isCollapsed ? 0 : 90))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(item.isCollapsed ? "Open it" : "Fold it to this row")
                Text(title).font(.sb(10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    let list = others()
                    if list.isEmpty { Text("Pin another page or tab to combine with it") }
                    ForEach(list, id: \.key) { o in Button("Combine with \(o.title)") { combine(o.key) } }
                    if inStack { Divider(); Button("Take out into its own window", action: takeOut) }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus").font(.sbIcon(10))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary).help(inStack ? "Combine this window with another, or take this card out" : "Combine with another pinned window")
                // the window's layer belongs to the window, so a stack shows it once, on its first card
                if !inStack || first {
                    Button { onTop.toggle(); toggleTop() } label: {
                        Image(systemName: onTop ? "square.stack.3d.up.fill" : "square.stack.3d.down.right").font(.sbIcon(10))
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(onTop ? "Above other windows; click to let other windows cover it" : "Among your windows; click to keep it above them")
                }
                Button(action: close) { Image(systemName: "xmark").font(.sbIcon(9.5, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(inStack ? "Unpin this card" : "Unpin from the desktop")
            }
            .padding(.horizontal, sc(10)).padding(.top, inStack && !first ? sc(6) : sc(10)).padding(.bottom, sc(2))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: toggleFold)
            if !item.isCollapsed { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GlassBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.cardSpace, item.space)
    }
}

/// A panel tab on its own: its sections, scrolling, without the tab bar.
struct DeskTab: View {
    let concern: SwitchboardConcern
    let space: String
    var body: some View {
        // the tab's top slot (a new-note box, a search) comes along, as in the panel;
        // the tab's own window space keeps its wheel and middle-click places apart from the popover's
        VStack(spacing: 0) {
            if let top = concern.pinned { top }
            ScrollViewReader { proxy in
                ScrollView(.vertical) { concern.content.padding(.bottom, sc(8)) }
                    .onReceive(FocusScroll.shared.$key) { k in
                        guard let k else { return }
                        DispatchQueue.main.async { withAnimation(Motion.fast) { proxy.scrollTo(k) } }
                    }
            }
            .scrollContentFrame()
        }
        // a resized panel grows the list with it
        .frame(minWidth: PT.width, idealWidth: PT.width, maxWidth: .infinity,
               minHeight: sw(160), idealHeight: min(PT.maxHeight, sw(520)), maxHeight: .infinity)
        .coordinateSpace(name: space)
        .environment(\.panelSpace, space)
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
    // panels saved before folding and stacking existed still load
    let old = #"[{"kind":"tab","id":"notes","onTop":false}]"#.data(using: .utf8)!
    let back2 = (try? JSONDecoder().decode([DeskItem].self, from: old)) ?? []
    check("a panel saved before folding existed still loads, open", back2.count == 1 && !back2[0].isCollapsed)

    // folding, combining and taking out, on a list of the probe's own
    let real = DeskPanels.saveKey
    DeskPanels.saveKey = "switchboard.deskPanels.probe"
    UserDefaults.standard.removeObject(forKey: DeskPanels.saveKey)
    defer { UserDefaults.standard.removeObject(forKey: DeskPanels.saveKey); DeskPanels.saveKey = real }
    let d = DeskPanels(probe: true)
    d.content = { i in AnyView(Text(i.id).frame(width: 200, height: 120)) }
    d.title = { $0.id }
    d.pin(.tab, "notes"); d.pin(.page, "limits")
    check("two pins make two windows", d.items.count == 2 && d.openKeys.count == 2)
    d.combine("page-limits", into: "tab-notes")
    let st = d.items.first
    check("combining makes one window holding both, in order",
          d.items.count == 1 && st?.kind == .stack && st?.children?.map(\.key) == ["tab-notes", "page-limits"] && d.openKeys.count == 1)
    check("a combined window saves and loads as one", (try? JSONDecoder().decode([DeskItem].self, from: JSONEncoder().encode(d.items)))?.first?.children?.count == 2)
    d.foldCard("page-limits", in: st?.key ?? "")
    check("a card in a stack folds and stays in the stack", d.items.first?.children?.last?.isCollapsed == true && d.items.count == 1)
    d.takeCardOut("page-limits", from: d.items.first?.key ?? "")
    check("taking out the second of two cards leaves two windows of one each",
          d.items.count == 2 && d.items.allSatisfy { $0.kind != .stack } && d.openKeys.count == 2)
    d.foldCard("tab-notes", in: "tab-notes")
    check("a single window folds to its title row", d.items.first { $0.key == "tab-notes" }?.isCollapsed == true)
    d.closeAll()
    return lines
}
