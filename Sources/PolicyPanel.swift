// PolicyPanel.swift
// The Switchboard panel: the menu bar icon's popover, one tab per concern.
// The Agents tab lists every policy in the policy registry with the control its
// type asks for (switch, segmented choice, menu, slider), a scope picker for
// per-repo overrides, and a timed flip ("snooze") on any switch or choice.
//
// Layout follows conventions/visual-design.md: weight and spacing carry the
// hierarchy, one type scale, colour only where it means something (a blocked
// action, a pending flip, a changed value).

import AppKit
import Combine
import SwiftUI

// ── Type and spacing, one place ─────────────────────────────────────────────

enum PT {
    static let title   = Font.system(size: 14, weight: .semibold)
    static let label   = Font.system(size: 12.5)
    static let caption = Font.system(size: 11)
    static let section = Font.system(size: 10, weight: .semibold)
    static let mono    = Font.system(size: 11.5, weight: .medium).monospacedDigit()
    static let rowV: CGFloat = 5.5
    static let rowH: CGFloat = 12
    static let gap: CGFloat = 12
    /// Wide enough for the longest label with a legacy (mouse) scrollbar showing.
    static let width: CGFloat = 424
    /// As tall as the screen allows, so the whole list usually fits unscrolled.
    static var maxHeight: CGFloat {
        let h = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, min(h - 150, 980))
    }
    static let control: CGFloat = 160
    static let segment: CGFloat = 52
    static let slider: CGFloat = 108
}

private let blockedTint = Color(nsColor: .systemRed)
private let snoozeTint = Color(nsColor: .systemTeal)
private let changedTint = Color(nsColor: .systemOrange)

// ── The panel ───────────────────────────────────────────────────────────────

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One concern the Switchboard shows, as a tab. Adding a concern is one new
/// file (a store and a view) plus one entry in `SwitchboardConcerns.all`.
struct SwitchboardConcern: Identifiable {
    let id: String
    let title: String          // the tab label
    let subtitle: String       // the line under "Switchboard"
    let icon: String           // SF Symbol for the tab and subtitle
    let footer: String
    let footerIcon: String
    let content: AnyView
    /// Runs when the panel opens and on the footer's reload button.
    var refresh: () -> Void = {}
    /// Stays above the scrolling content, such as a search field.
    var pinned: AnyView? = nil
    /// False hides the tab, as Approvals is hidden while nothing waits.
    var isShown: () -> Bool = { true }
    /// A number on the tab label, or nil for none.
    var badge: () -> Int? = { nil }
}

/// The registry: every concern, in tab order.
enum SwitchboardConcerns {
    /// A concern whose backing tool is not installed is left out, so a fresh
    /// Mac shows fewer tabs rather than an error.
    static func all(policy: PolicyStore, usage: UsageStore, lights: LightsStore, controls: ControlsStore) -> [SwitchboardConcern] {
        Catalog.reload = { id in
            DispatchQueue.main.async { if let read = catalogReaders[id] { policy.reloadCatalog(id, read) } }
        }
        let tabs = registry(policy: policy, usage: usage, lights: lights, controls: controls)
            .filter { $0.id != "agents" || Integrations.policyStore }
            .filter { $0.id != "remote" || Integrations.csync }
        // Settings lists every other tab, so it is built from the rest. Approvals
        // cannot be hidden: it is how a waiting push reaches you.
        let listed = tabs.filter { $0.id != "approvals" }.map { (id: $0.id, title: $0.title, icon: $0.icon) }
        let settings = SwitchboardConcern(id: "settings", title: "Settings", subtitle: "What the panel shows", icon: Icons.tab["settings"]!,
                                          footer: "Hidden tabs and sections are not read, so they cost nothing.", footerIcon: "eye.slash",
                                          content: AnyView(SettingsTabView(store: policy, tabs: listed)),
                                          pinned: AnyView(SearchField(text: Binding(get: { policy.queries["settings"] ?? "" },
                                                                                    set: { policy.queries["settings"] = $0 }),
                                                                      prompt: "Search tabs, sections and preview items")))
        return tabs + [settings]
    }

    private static func registry(policy: PolicyStore, usage: UsageStore, lights: LightsStore, controls: ControlsStore) -> [SwitchboardConcern] {
        [
            SwitchboardConcern(id: "approvals", title: "Approvals", subtitle: "Waiting on you", icon: Icons.tab["approvals"]!,
                               footer: "Approve writes a one-time pass and wakes the session.", footerIcon: "checkmark.seal",
                               content: AnyView(SystemTabView(store: policy, source: .approvals)),
                               refresh: { policy.requestSystemRefresh() },
                               isShown: { !policy.needGroups.isEmpty },
                               badge: { policy.needsWaiting > 0 ? policy.needsWaiting : nil }),
            SwitchboardConcern(id: "agents", title: "Agents", subtitle: "What agents may do", icon: Icons.tab["agents"]!,
                               footer: "Applies to every session at once. Only you can change it.", footerIcon: "bolt.fill",
                               content: AnyView(AgentsTabView(store: policy)),
                               refresh: { policy.reload() }),
            SwitchboardConcern(id: "usage", title: "Usage", subtitle: "Claude and Codex limits", icon: Icons.tab["usage"]!,
                               footer: "Bars mark the thresholds that act on them.", footerIcon: "line.diagonal",
                               content: AnyView(UsageTabView(usage: usage, policy: policy)),
                               refresh: { usage.reload() }),
            SwitchboardConcern(id: "system", title: "Machine", subtitle: "This Mac's switches", icon: Icons.tab["system"]!,
                               footer: "The timer icon flips a switch for a while.", footerIcon: "timer",
                               content: AnyView(SystemTabView(store: policy)),
                               refresh: { policy.requestSystemRefresh() }),
            SwitchboardConcern(id: "home", title: "Home", subtitle: "Your home network", icon: Icons.tab["home"]!,
                               footer: "Talks to the bulbs directly over the LAN.", footerIcon: "wifi",
                               content: AnyView(LightsTabView(lights: lights)),
                               refresh: { lights.discover() }),
            SwitchboardConcern(id: "controls", title: "Controls", subtitle: "Sound, display, Wi-Fi, Bluetooth", icon: Icons.tab["controls"]!,
                               footer: "Talks to macOS directly; nothing to install.", footerIcon: "apple.logo",
                               content: AnyView(ControlsTabView(controls: controls)),
                               refresh: { controls.load(devices: true) }),
            SwitchboardConcern(id: "remote", title: "Remote", subtitle: "Machines you drive with csync", icon: Icons.tab["remote"]!,
                               footer: "Every action is a csync command, recorded in its log.", footerIcon: "terminal",
                               content: AnyView(SystemTabView(store: policy, source: .remote)),
                               refresh: { policy.requestSystemRefresh() }),
            SwitchboardConcern(id: "runtime", title: "Runtime", subtitle: "Everything that runs", icon: Icons.tab["runtime"]!,
                               footer: "Stop and Disable ask first; a command copies instead of opening a terminal.", footerIcon: "doc.on.doc",
                               content: AnyView(SystemTabView(store: policy, source: .catalog("runtime"))),
                               refresh: { policy.requestSystemRefresh() },
                               pinned: AnyView(SearchField(text: Binding(get: { policy.queries["runtime"] ?? "" },
                                                                         set: { policy.queries["runtime"] = $0 }),
                                                           prompt: "Search services, ports, models and jobs"))),
            SwitchboardConcern(id: "plugins", title: "Claude MCP", subtitle: "Plugins and MCP servers", icon: Icons.tab["plugins"]!,
                               footer: "On and off apply to new sessions. MCP keys and tokens are never shown.", footerIcon: "lock",
                               content: AnyView(SystemTabView(store: policy, source: .catalog("plugins"))),
                               refresh: { policy.reloadCatalog("plugins", PluginsCatalog.groups) },
                               pinned: AnyView(ScopedSearch(store: policy, id: "plugins", prompt: "Search plugins and MCP servers"))),
            SwitchboardConcern(id: "timers", title: "Timers", subtitle: "Countdowns that go off with a sound", icon: Icons.tab["timers"]!,
                               footer: "A timer keeps running if the app restarts. + adds a minute.", footerIcon: "bell",
                               content: AnyView(TimersTabView(timers: TimerStore.shared))),
            SwitchboardConcern(id: "notes", title: "Notes", subtitle: "Notes at hand, one file each", icon: Icons.tab["notes"]!,
                               footer: "Drag the grip to reorder. Point at a note, or right-click it, to copy it.",
                               footerIcon: "doc.text",
                               content: AnyView(NotesTabView(notes: NotesStore.shared)),
                               refresh: { NotesStore.shared.loadInBackground() },
                               pinned: AnyView(NoteCompose(notes: NotesStore.shared))),
            catalogTab(policy, id: "rules", title: "Hooks", subtitle: "Rules, gates and hook scripts", icon: Icons.tab["rules"]!,
                       footer: "Problems sort first: a hook with no event, or one whose file is gone.",
                       search: "Search rules, gates and hooks", read: RulesCatalog.groups),
            catalogTab(policy, id: "queue", title: "Queue", subtitle: "What gcc has lined up to happen", icon: Icons.tab["queue"]!,
                       footer: "A cron duty whose session has ended cannot fire; those sort first.",
                       search: "Search schedules, duties, deploys and proposals", read: QueueCatalog.groups),
            catalogTab(policy, id: "ledger", title: "Ledger", subtitle: "Mistakes and the improvement backlog", icon: Icons.tab["ledger"]!,
                       footer: "Mistakes sort by how often they recur; each row copies its CLI line.",
                       search: "Search mistakes and proposals", read: LedgerCatalog.groups),
            catalogTab(policy, id: "library", title: "Library", subtitle: "Skills, docs, personas, scripts", icon: Icons.tab["library"]!,
                       footer: "Open a row for its details; the path copies on click.",
                       search: "Search skills, docs, personas and scripts", read: LibraryCatalog.groups),
        ]
    }

    /// A list tab on the catalog machinery: sections read off the main
    /// thread, a pinned search across all of them, rows that open and copy.
    static func catalogTab(_ policy: PolicyStore, id: String, title: String, subtitle: String, icon: String,
                           footer: String, search: String, read: @escaping () -> [SystemGroup]) -> SwitchboardConcern {
        SwitchboardConcern(id: id, title: title, subtitle: subtitle, icon: icon,
                           footer: footer, footerIcon: "doc.on.doc",
                           content: AnyView(SystemTabView(store: policy, source: .catalog(id))),
                           refresh: { policy.reloadCatalog(id, read) },
                           pinned: AnyView(SearchField(text: Binding(get: { policy.queries[id] ?? "" },
                                                                     set: { policy.queries[id] = $0 }),
                                                       prompt: search)))
    }
}

struct PolicyPanel: View {
    let concerns: [SwitchboardConcern]
    /// Feeds the Needs-you strip and decides which tabs show.
    @ObservedObject var store: PolicyStore
    /// Fixed-height rendering for snapshots, where a ScrollView would clip.
    var unbounded = false
    /// Pins a tab for snapshots; nil follows the owner's last choice.
    var forcedTab: String? = nil
    @State private var contentHeight: CGFloat = 0
    static let tabKey = "policyPanel.tab"
    @AppStorage(PolicyPanel.tabKey) private var storedTab = "agents"

    /// Visible tabs in the owner's order, so a drag in Settings moves the bar at once.
    private var shown: [SwitchboardConcern] {
        let rank = Dictionary(store.tabOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return concerns.filter { $0.isShown() && !store.hiddenTabs.contains($0.id) }
            .sorted { (rank[$0.id] ?? 99) < (rank[$1.id] ?? 99) }
    }

    /// The chosen tab, or the first other one when the chosen tab is hidden,
    /// so Approvals emptying out never leaves the panel on a blank tab.
    private var current: SwitchboardConcern {
        // The Skills tab became Library > Skills.
        let id = (forcedTab ?? storedTab) == "skills" ? "library" : (forcedTab ?? storedTab)
        let tabs = shown
        return tabs.first { $0.id == id } ?? tabs.first { $0.id != "approvals" } ?? concerns[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let pinned = current.pinned { pinned }
            if unbounded {
                current.content
            } else {
                // Sized to the content, up to the screen cap, so a short tab
                // does not leave the popover padded with space.
                ScrollView(.vertical, showsIndicators: true) {
                    current.content.background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
                }
                .frame(height: min(max(contentHeight, 120), PT.maxHeight))
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: PT.width)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Switchboard", systemImage: "slider.vertical.3").font(PT.title)
                Spacer(minLength: 8)
                Text(current.subtitle).font(PT.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                ForEach(shown.filter { Visibility.space(of: $0.id) == nil }) { c in headerButton(c) }
            }
            spaceBar
            if currentSpaceTabs.count > 1 { subTabs }
        }
        .padding(.horizontal, PT.gap)
        .padding(.vertical, 10)
    }

    private func open(_ c: SwitchboardConcern) {
        storedTab = c.id
        Visibility.rememberTab(c.id)
        c.refresh()
    }

    /// Settings and Approvals: small icons in the header, since they are
    /// about the panel and about you, not a place among the others.
    private func headerButton(_ c: SwitchboardConcern) -> some View {
        let on = c.id == current.id
        return Button { open(c) } label: {
            HStack(spacing: 3) {
                Image(systemName: c.icon).font(.system(size: 12, weight: on ? .semibold : .regular))
                if let n = c.badge() { TabBadge(count: n, onAccent: on) }
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.7))
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.title + ": " + c.subtitle)
    }

    /// Spaces that have at least one visible tab, with those tabs in the owner's order.
    private var spaces: [(id: String, title: String, icon: String, tabs: [SwitchboardConcern])] {
        Visibility.spaces.compactMap { s in
            let tabs = shown.filter { s.tabs.contains($0.id) }
            return tabs.isEmpty ? nil : (s.id, s.title, s.icon, tabs)
        }
    }

    private var currentSpaceTabs: [SwitchboardConcern] {
        spaces.first { $0.id == Visibility.space(of: current.id) }?.tabs ?? []
    }

    // A drawn bar: the native segmented control drops a label's icon on macOS.
    private var spaceBar: some View {
        HStack(spacing: 2) {
            ForEach(spaces, id: \.id) { s in
                let on = s.id == Visibility.space(of: current.id)
                let badge = s.tabs.compactMap { $0.badge() }.reduce(0, +)
                Button {
                    let last = Visibility.lastTab(in: s.id)
                    open(s.tabs.first { $0.id == last } ?? s.tabs[0])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: s.icon).font(.system(size: 10.5))
                        Text(s.title).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1)
                        if badge > 0 { TabBadge(count: badge, onAccent: on) }
                        else if let l = s.tabs.compactMap({ store.problemLevels[$0.id] }).max() { ProblemMark(level: l, onAccent: on) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.tabs.map(\.title).joined(separator: ", "))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
    }

    /// The chosen space's tabs, each with its own icon, the current one underlined.
    private var subTabs: some View {
        HStack(spacing: 14) {
            ForEach(currentSpaceTabs) { c in
                let on = c.id == current.id
                Button { open(c) } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: c.icon).font(.system(size: 10.5))
                            Text(c.title).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1)
                            if let n = c.badge() { TabBadge(count: n, onAccent: false) }
                            else if let l = store.problemLevels[c.id] { ProblemMark(level: l) }
                        }
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        Capsule().fill(on ? Color.accentColor : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.subtitle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: current.footerIcon).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(current.footer).font(PT.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { current.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Reload this tab")
        }
        .padding(.horizontal, PT.gap)
        .padding(.vertical, 8)
    }
}

// ── The Agents concern: the policy store, with its scope picker ────────────

struct AgentsTabView: View {
    @ObservedObject var store: PolicyStore

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            HStack(spacing: 6) {
                Text("Applies to").font(PT.caption).foregroundStyle(.secondary)
                scopeMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            // A write's refusal shows on its own row; this line is only for the
            // store itself failing to load.
            if let e = store.error {
                ReadingStatus(state: store.items.isEmpty ? .failed(e) : .stale(store.now, e),
                              retry: { store.reload() })
                    .padding(.horizontal, 4)
            }
            if store.scopeIsProject, case .project(let root) = store.scope {
                Text("Overrides for \(abbreviateHome(root)). A row with no override follows the Everywhere value.")
                    .font(PT.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if store.items.isEmpty && store.error == nil {
                ReadingStatus(state: .loading).padding(.horizontal, 4)
            }
            // Usage thresholds (the *_pct limits) live on the Usage tab, next
            // to the bars they act on.
            ForEach(store.groups, id: \.name) { g in
                let items = g.items.filter { !($0.group == "Limits" && $0.key.hasSuffix("_pct")) }
                if !items.isEmpty { PolicyGroupView(name: g.name, items: items, store: store) }
            }
            // Machine groups that moved here (Context). They are machine-wide, so
            // they show under Everywhere only, never as a project override.
            if !store.scopeIsProject {
                ForEach(store.systemGroups.filter { SystemTabView.groupHome[$0.title] == "agents" }) { g in
                    VStack(alignment: .leading, spacing: 5) {
                        GroupHeader(name: g.title)
                        if let st = g.status { ReadingStatus(state: st).padding(.horizontal, 4) }
                        Card {
                            ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, row in
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                SystemRowView(row: row, store: store)
                            }
                        }
                    }
                }
            }
        }
        .padding(PT.gap)
    }

    @State private var showScopes = false

    // A list, not a native menu: menus cannot draw a two-line item or hold a
    // button inside an item, and each project row wants both.
    private var scopeMenu: some View {
        Button { showScopes.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: store.scopeIsProject ? "folder" : "globe")
                Text(store.scope.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(PT.caption)
        }
        .buttonStyle(.borderless)
        .help("Where a change applies: everywhere, or one repository's override")
        .popover(isPresented: $showScopes, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.scopes, id: \.self) { s in ScopeRow(scope: s, selected: s == store.scope) {
                    store.scope = s
                    store.reload()
                    showScopes = false
                } }
            }
            .padding(6)
            .frame(width: 300)
        }
    }
}

/// One scope in the picker: name over its dimmed path, with a folder button.
private struct ScopeRow: View {
    let scope: PolicyScope
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                else { Color.clear }
            }
            .frame(width: 12, height: 12)
            .foregroundStyle(Color.accentColor)
            Image(systemName: isGlobal ? "globe" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(isGlobal ? Color.secondary : Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(scope.title).font(PT.label).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if case .project(let root) = scope {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: root)) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(abbreviateHome(root)) in Finder")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: pick)
    }

    private var isGlobal: Bool { if case .global = scope { return true }; return false }
    private var subtitle: String {
        switch scope {
        case .global: return "All projects, unless one overrides"
        case .project(let root): return abbreviateHome(root)
        }
    }
}

// ── The Machine concern: the bar's system switches ─────────────────────────

struct SystemTabView: View {
    @ObservedObject var store: PolicyStore
    /// Which of the store's group lists this tab draws with the shared rows.
    enum Source: Equatable { case machine, remote, approvals, catalog(String) }
    var source: Source = .machine

    /// Machine groups that live on another tab now, by that tab's id. The
    /// snapshot still builds them; only where they are drawn changes.
    static let groupHome: [String: String] = Visibility.groupTab.filter { $0.value != "system" }

    private var groups: [SystemGroup] {
        switch source {
        case .machine: return store.systemGroups.filter { SystemTabView.groupHome[$0.title] == nil }
        case .remote: return store.remoteGroups
        case .approvals: return store.needGroups
        case .catalog(let id):
            let q = store.queries[id] ?? ""
            let moved = store.systemGroups.filter { SystemTabView.groupHome[$0.title] == id }
            // Sections titled "Project …" apply in one repo; the scope filter picks them in or out.
            let scoped = (moved + (store.catalogs[id] ?? [])).filter { g in
                if store.hiddenSections.contains(id + "::" + g.title) { return false }
                switch store.queries[id + "::scope"] ?? "all" {
                case "everywhere": return !g.title.hasPrefix("Project")
                case "project": return g.title.hasPrefix("Project")
                default: return true
                }
            }
            let all = Catalog.filter(scoped, q)
            return q.isEmpty ? all.map { Catalog.preview($0, tab: id, store: store) } : all
        }
    }

    /// Words for an empty tab: nothing waiting, no search match, or still reading.
    @ViewBuilder private var emptyLine: some View {
        switch source {
        case .approvals:
            Text("Nothing is waiting on you.").font(PT.caption).foregroundStyle(.secondary)
        case .catalog(let id) where store.catalogs[id] != nil || !(store.queries[id] ?? "").isEmpty:
            Text("Nothing matches \u{201C}\(store.queries[id] ?? "")\u{201D}.").font(PT.caption).foregroundStyle(.secondary)
        default:
            ReadingStatus(state: .loading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            if groups.isEmpty { emptyLine.padding(.horizontal, 4) }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: g.title)
                    if let st = g.status {
                        ReadingStatus(state: st).padding(.horizontal, 4)
                    }
                    if !g.rows.isEmpty {
                        Card {
                            ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, row in
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                SystemRowView(row: row, store: store)
                            }
                        }
                    }
                }
            }
        }
        .padding(PT.gap)
    }
}

// ── One group: a tracked header over a rounded card of rows ────────────────

private struct PolicyGroupView: View {
    let name: String
    let items: [PolicyItem]
    @ObservedObject var store: PolicyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: name)
            Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    PolicyRowView(item: item, store: store)
                }
            }
        }
    }
}

// ── Shared chrome: the tracked group label and the rounded card ────────────

/// The round count on a tab label, in the Needs-you yellow so it reads as
/// "waiting on you" on any tab, selected or not.
struct TabBadge: View {
    let count: Int
    var onAccent = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, count > 9 ? 4 : 0)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(Color(nsColor: menuYellow)))
            .overlay(Capsule().strokeBorder(onAccent ? Color.white.opacity(0.7) : .clear, lineWidth: 1))
            .help("\(count) waiting on you")
    }
}

/// The dot beside a space or tab showing something wrong: red for an error,
/// orange for a warning, the colours the badges use.
struct ProblemMark: View {
    var level: ProblemLevel = .error
    var onAccent = false

    var body: some View {
        Circle().fill(level.tint)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(onAccent ? Color.white.opacity(0.8) : .clear, lineWidth: 1))
            .help(level == .error ? "Something here is broken" : "Something here could use a look")
    }
}

extension ProblemLevel {
    var color: NSColor { self == .error ? menuRed : .systemOrange }
    var tint: Color { Color(nsColor: color) }
    /// A different shape per level as well as a colour, so the two read apart without colour.
    var icon: String { self == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill" }
}

struct GroupHeader: View {
    let name: String
    var body: some View {
        HStack(spacing: 5) {
            if let icon = Icons.section[name] {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            }
            Text(name.uppercased()).font(PT.section).tracking(0.7)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }

}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// ── A system row: the dropdown Switchboard's row, as a panel row ───────────

struct SystemRowView: View {
    let row: SystemRow
    @ObservedObject var store: PolicyStore
    /// A flip asked for and not yet seen by the next probe.
    @State private var pendingFlip: PendingChange<Bool>?
    @State private var failure: String?
    @State private var expanded: Bool
    @State private var hovering = false
    /// The row button still working, and since when.
    @State private var busyButton: String?
    @State private var busySince = Date()
    @State private var copiedButton: String?
    /// An ask button waiting for its line of text.
    @State private var asking: RowButton?
    @State private var askDraft = ""
    @FocusState private var askFocused: Bool
    var indent: CGFloat = 0

    init(row: SystemRow, store: PolicyStore, indent: CGFloat = 0) {
        self.row = row
        self.store = store
        self.indent = indent
        // Headless --expand opens the top rows only, so nested lists stay folded.
        _expanded = State(initialValue: (SystemRowView.startExpanded && indent == 0) || row.startsOpen)
    }

    /// Headless renders set this (--expand) so opened rows can be checked.
    static var startExpanded = false

    private var opens: Bool { !row.children.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            mainLine
                .background(hovering && (opens || row.menu != nil) ? Color.primary.opacity(0.05) : .clear)
                .onHover { hovering = $0 }
                // The whole row is the target for a row that opens something;
                // the small chevron alone was too hard to hit.
                .onTapGesture {
                    if opens { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                    else if let menu = row.menu { menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
                    // A row whose one action is a copy (a file path) copies anywhere it is clicked.
                    else if row.buttons.count == 1, case .copy = row.buttons[0].kind { press(row.buttons[0]) }
                    // So does a row whose one action is a labelled button ("Show all").
                    else if row.buttonLabel != nil, row.buttons.isEmpty, let a = row.action { a() }
                }
            if let b = asking, case .ask(let placeholder, _) = b.kind {
                HStack(spacing: 6) {
                    TextField(placeholder, text: $askDraft)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focused($askFocused)
                        .onSubmit { submitAsk(b) }
                        .onExitCommand { asking = nil }
                    Button("Cancel") { asking = nil }.controlSize(.small)
                }
                .padding(.leading, PT.rowH + indent).padding(.trailing, PT.rowH).padding(.bottom, PT.rowV + 2)
            }
            if opens && expanded {
                VStack(spacing: 0) {
                    ForEach(row.children) { child in
                        Divider().padding(.leading, PT.rowH + indent + 14)
                        AnyView(SystemRowView(row: child, store: store, indent: indent + 14))
                    }
                }
                .background(Color.primary.opacity(0.025))
            }
            if let f = failure {
                RowFailure(message: f, retry: row.isSwitch ? { flip(to: !row.isOn) } : nil,
                           dismiss: { failure = nil })
                    .padding(.leading, indent)
            }
        }
        // A switch reports nothing back; the next probe showing it in the asked
        // position is the confirmation.
        .onChange(of: row.isOn) { now in
            if pendingFlip?.target == now { pendingFlip = nil; failure = nil }
        }
    }

    private func flip(to on: Bool) {
        let p = PendingChange(target: on, since: Date())
        pendingFlip = p
        failure = nil
        row.action?()
        // Past the grace time, the verdict is a snapshot started after it, however
        // long that takes: a slow helper is not a switch that failed.
        let id = row.id, label = row.label
        DispatchQueue.main.asyncAfter(deadline: .now() + Pending.giveUpAfter) {
            guard pendingFlip == p else { return }
            store.afterFreshSnapshot {
                guard pendingFlip == p else { return }
                pendingFlip = nil
                let now = store.systemRowIsOn(id)
                if now == on { failure = nil; return }
                failure = "\(label) did not turn \(on ? "on" : "off")." + (now.map { " It is still \($0 ? "on" : "off")." } ?? "")
                dwarn("switch did not confirm: \(label) -> \(on ? "on" : "off")")
            }
        }
    }

    private var mainLine: some View {
        HStack(alignment: .center, spacing: 8) {
            if let icon = row.icon {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(PT.label).fixedSize(horizontal: false, vertical: true)
                    .strikethrough(row.struck)
                    .foregroundStyle(row.struck ? .secondary : row.enabled || !row.isSwitch ? .primary : .secondary)
                if let t = row.timer, let key = row.timerKey {
                    HStack(spacing: 4) {
                        Text("→ \(t.restoreOn ? "On" : "Off") in \(countdown(to: t.until, now: store.now))")
                            .lineLimit(1)
                        Button { store.cancelSystemTimer(key) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel the timer and keep the current state")
                    }
                    .font(PT.caption).foregroundStyle(snoozeTint)
                } else if !row.note.isEmpty {
                    Text(row.note).font(PT.caption).foregroundStyle(.secondary)
                        .lineLimit(row.noteLines == 0 ? nil : row.noteLines).fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(row.struck ? 0.55 : 1)
            Spacer(minLength: 6)
            if let p = pendingFlip { PendingMark(since: p.since) }
            else if busyButton != nil { PendingMark(since: busySince) }
            else if let key = row.timerKey { timerMenu(key).frame(width: 18) }
            // Fixed size: long wrapping text beside them must never squeeze a button out.
            HStack(spacing: 8) {
                ForEach(row.buttons.indices, id: \.self) { i in rowButton(row.buttons[i]) }
            }
            .fixedSize()
            if let link = row.link, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(link)")
            }
            control.frame(minWidth: row.showsBadge ? 44 : 0, alignment: .trailing)
        }
        .padding(.leading, PT.rowH + indent)
        .padding(.trailing, PT.rowH)
        .padding(.vertical, PT.rowV)
        .contentShape(Rectangle())
        .help(row.tip)
    }

    // ── Row buttons ──

    /// Every row button is an icon, like the timer beside it; its name moves
    /// to the tooltip. One table so a new button can never come out as text.
    static func symbol(for label: String) -> String {
        switch label {
        case "Copy": return "doc.on.doc"
        case "All": return "chevron.down"
        case "Fewer": return "chevron.up"
        case "Transcript": return "text.bubble"
        case "Start": return "play.fill"
        case "Stop": return "stop.fill"
        case "Open": return "doc.text"
        case "Reap": return "trash"
        case "Load": return "arrow.down.circle"
        case "Unload": return "eject"
        case "Wake": return "power"
        case "Forget": return "minus.circle"
        case "Add…": return "plus.circle"
        case "Re-arm", "Lift": return "checkmark.shield"
        case "Fix": return "wrench.and.screwdriver"
        case "Screenshot": return "camera"
        case "Shell": return "terminal"
        case "Teardown": return "xmark.circle"
        case "Invite": return "person.badge.plus"
        case "Finder": return "folder"
        case "Terminal": return "apple.terminal"
        case "Editor": return "chevron.left.forwardslash.chevron.right"
        case "Fetch": return "arrow.triangle.2.circlepath"
        case "Prune": return "scissors"
        case "Eject": return "eject.fill"
        case "Disk Utility": return "internaldrive"
        case "Kill": return "xmark.octagon"
        case "Disable": return "nosign"
        case "Enable": return "checkmark.circle"
        case "Cancel": return "xmark.circle"
        case "Approve": return "checkmark.seal.fill"
        default: return "circle"
        }
    }

    private func iconButton(_ symbol: String, tip: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .help(tip)
    }

    @ViewBuilder private func rowButton(_ b: RowButton) -> some View {
        if case .menu(let items) = b.kind {
            Menu {
                ForEach(items.indices, id: \.self) { i in
                    if let work = items[i].run {
                        Button(items[i].title) { runWork(b, items[i].title, work) }
                    } else {
                        Divider()
                    }
                }
            } label: {
                Image(systemName: b.icon ?? "ellipsis.circle").font(.system(size: 12)).frame(width: 18, height: 16)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .disabled(busyButton != nil)
            .help(b.help.isEmpty ? b.label : b.help)
        } else {
            plainRowButton(b)
        }
    }

    private func plainRowButton(_ b: RowButton) -> some View {
        let copied = copiedButton == b.label
        return iconButton(copied ? "checkmark" : (b.icon ?? Self.symbol(for: b.label)),
                          tip: copied ? "Copied" : (b.help.isEmpty ? b.label : "\(b.label): \(b.help)"),
                          tint: copied ? Color(nsColor: .systemGreen) : nil) { press(b) }
            .disabled(busyButton != nil)
    }

    private func press(_ b: RowButton) {
        failure = nil
        switch b.kind {
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedButton = b.label
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedButton == b.label { copiedButton = nil }
            }
        case .ask:
            askDraft = ""
            asking = b
            // A menu bar app only takes keystrokes once it is the active app.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { askFocused = true }
        case .menu:
            break
        case .run(let work):
            if let question = b.confirm {
                let a = NSAlert()
                a.messageText = question
                a.alertStyle = .warning
                a.addButton(withTitle: b.label)
                a.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard a.runModal() == .alertFirstButtonReturn else { return }
            }
            runWork(b, b.doing ?? "\(b.label.lowercased()) \(row.label)", work)
        }
    }

    /// Run one action off the main thread with the row's spinner, and turn
    /// what it reports into the row's failure line.
    private func runWork(_ b: RowButton, _ doing: String, _ work: @escaping () -> String?) {
        failure = nil
        busyButton = b.label
        busySince = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let err = work()
            DispatchQueue.main.async {
                busyButton = nil
                if let err = err {
                    failure = "Couldn't \(doing): \(err)"
                    dwarn("row button failed: \(doing): \(err)")
                }
            }
        }
    }

    private func submitAsk(_ b: RowButton) {
        guard case .ask(_, let work) = b.kind else { return }
        let text = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        asking = nil
        failure = nil
        busyButton = b.label
        busySince = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let err = work(text)
            DispatchQueue.main.async {
                busyButton = nil
                if let err = err {
                    failure = "Couldn't \(b.doing ?? b.label.lowercased()): \(err)"
                    dwarn("row ask failed: \(b.label) \(text): \(err)")
                } else {
                    copiedButton = b.label
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedButton == b.label { copiedButton = nil }
                    }
                }
            }
        }
    }

    // ── Timers: flip now, flip back later ──

    private func timerMenu(_ key: String) -> some View {
        let active = row.timer != nil
        // While a timer runs the switch shows the temporary state; the title says where it goes back to.
        let title = active ? "Change when it turns back \(row.timer!.restoreOn ? "on" : "off")"
                           : "\(row.isOn ? "Off" : "On") until…"
        return WhenButton(title: title, presets: WhenPreset.short,
                          extra: active ? [("End now", { store.endSystemTimerNow(key) }),
                                           ("Cancel the timer", { store.cancelSystemTimer(key) })] : [],
                          initial: row.timer?.until,
                          onPick: { d, _ in store.startSystemTimer(key, d) }) {
            Image(systemName: active ? "timer.circle.fill" : "timer")
                .font(.system(size: 11))
                .foregroundStyle(active ? AnyShapeStyle(snoozeTint) : AnyShapeStyle(.tertiary))
        }
        .fixedSize()
        .help(row.isOn ? "Turn this off for a while" : "Turn this on for a while")
    }


    @ViewBuilder private var control: some View {
        if opens {
            HStack(spacing: 4) {
                if row.showsBadge { StateBadge(state: row.state) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        } else if let label = row.buttonLabel, let action = row.action {
            iconButton(Self.symbol(for: label), tip: "\(label): \(row.tip)", action: action)
        } else if let choices = row.choices {
            Picker("", selection: Binding(get: { row.selected }, set: { row.onChoose?($0) })) {
                ForEach(Array(choices.enumerated()), id: \.offset) { i, c in Text(c).tag(i) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(!row.enabled)
        } else if row.isSwitch {
            Toggle("", isOn: Binding(get: { pendingFlip?.target ?? row.isOn },
                                     set: { flip(to: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!row.enabled)
                .allowsHitTesting(pendingFlip == nil)
        } else if let menu = row.menu {
            // The dropdown's own drill-down menu, popped where the click was.
            Button {
                menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } label: {
                HStack(spacing: 4) {
                    StateBadge(state: row.state)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else if let action = row.action, row.enabled {
            Button(action: action) { StateBadge(state: row.state) }
                .buttonStyle(.plain)
        } else if row.showsBadge {
            StateBadge(state: row.state)
        }
    }
}

/// The dropdown's pill: filled and tinted when engaged, hollow when not.
private struct StateBadge: View {
    let state: SystemRow.State

    private var text: String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .count(let n, _): return "\(n)"
        case .ok: return "ok"
        }
    }
    private var tint: NSColor? {
        switch state {
        case .on(let c), .count(_, let c): return c
        case .off, .ok: return nil
        }
    }

    var body: some View {
        let label = Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 1.5)
        if let t = tint {
            label.foregroundStyle(Color(nsColor: t))
                .background(Capsule().fill(Color(nsColor: t).opacity(0.18)))
        } else {
            label.foregroundStyle(.secondary)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2)))
        }
    }
}

// ── One row: label and state on the left, the control on the right ─────────

struct PolicyRowView: View {
    let item: PolicyItem
    @ObservedObject var store: PolicyStore
    @State private var draft: Double = 0
    @State private var dragging = false

    private var pendingChange: PendingChange<PolicyValue?>? { store.pending[item.key] }
    /// What the row shows: the value just asked for while it is being saved,
    /// otherwise the stored one.
    private var shown: PolicyValue { (pendingChange?.target ?? nil) ?? item.value }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.label).font(PT.label).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if !item.isDefault {
                            Circle().fill(changedTint).frame(width: 5, height: 5)
                                .help("Changed from the default (\(item.defaultValue.cli))")
                        }
                    }
                    caption
                }
                Spacer(minLength: 6)
                // Fixed columns: the clock and the control line up down the whole
                // panel whatever each control's own width is. While a change is
                // saving, the clock's slot holds the pending mark instead.
                Group {
                    if let p = pendingChange { PendingMark(since: p.since) } else { snoozeMenu }
                }
                .frame(width: 18, alignment: .center)
                control
                    .allowsHitTesting(pendingChange == nil)
                    .frame(width: PT.control, alignment: .trailing)
            }
            .padding(.horizontal, PT.rowH)
            .padding(.vertical, PT.rowV)
            if let f = store.failures[item.key] {
                RowFailure(message: f, retry: { store.retry(item.key) },
                           dismiss: { store.failures[item.key] = nil })
            }
        }
        .contentShape(Rectangle())
        .help(item.help)
    }

    // What sits under the label: a pending flip, an override, or nothing.
    @ViewBuilder private var caption: some View {
        if let z = item.snooze, !z.expired {
            HStack(spacing: 4) {
                Text("→ \(word(z.then)) in \(countdown(to: z.until, now: store.now))")
                    .lineLimit(1)
                Button { store.cancelSnooze(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Cancel the timed change and keep the current value")
            }
            .font(PT.caption).foregroundStyle(snoozeTint)
        } else if store.scopeIsProject {
            if item.source == "project" {
                resettable("Everywhere is \(word(item.globalValue ?? item.defaultValue))")
            } else {
                Text("Follows Everywhere").font(PT.caption).foregroundStyle(.tertiary)
            }
        } else if store.hasOwnValue(item) && !item.isDefault {
            resettable("Default is \(word(item.defaultValue))")
        }
    }

    private func resettable(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(PT.caption).foregroundStyle(.secondary)
            Button { store.reset(item) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(store.scopeIsProject ? "Remove this repo's override" : "Back to the default")
        }
    }

    // ── The control, chosen by the policy's declared type ──

    @ViewBuilder private var control: some View {
        switch item.kind {
        case .toggle:
            let allowed = shown == .text("allow")
            HStack(spacing: 8) {
                Text(allowed ? "Allowed" : "Blocked")
                    .font(PT.caption)
                    .foregroundStyle(allowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(blockedTint))
                Toggle("", isOn: Binding(
                    get: { allowed },
                    set: { store.set(item, .text($0 ? "allow" : "block")) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        case .segmented(let opts):
            Picker("", selection: Binding(
                get: { shown.cli },
                set: { store.set(item, .text($0)) })) {
                ForEach(opts, id: \.self) { Text(word(.text($0))).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: CGFloat(max(2, opts.count)) * PT.segment)
        case .menu(let opts):
            Picker("", selection: Binding(
                get: { shown.cli },
                set: { store.set(item, .text($0)) })) {
                ForEach(opts, id: \.self) { Text(word(.text($0))).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        case .slider(let lo, let hi, let step, let unit):
            HStack(spacing: 8) {
                // Snapped by hand rather than with `step:`, which draws a tick
                // mark per step and turns a 50-100 range into a row of dots.
                Slider(value: Binding(
                    get: { dragging ? draft : numeric(shown) },
                    set: { draft = (($0 - lo) / step).rounded() * step + lo }),
                       in: lo...hi,
                       onEditingChanged: { editing in
                           if editing { draft = numeric(item.value); dragging = true }
                           else { dragging = false; store.set(item, .number(draft)) }
                       })
                    .controlSize(.small)
                    .frame(width: PT.slider)
                Text("\(Int(dragging ? draft : numeric(shown)))\(unit)")
                    .font(PT.mono)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // ── Timed flip: switch to another value later, keep this one until then ──

    @ViewBuilder private var snoozeMenu: some View {
        let targets = item.options.filter { $0 != item.value }
        if !targets.isEmpty {
            let active = item.snooze.map { !$0.expired } ?? false
            WhenButton(title: "Switch later, keeping \(word(item.value)) until then", presets: WhenPreset.short,
                       choices: targets.map { "To " + word($0) },
                       extra: active ? [("Cancel the timed change", { store.cancelSnooze(item) })] : [],
                       onPick: { d, i in
                           store.snooze(item, seconds: max(60, Int(d.timeIntervalSinceNow)), then: targets[min(i, targets.count - 1)])
                       }) {
                Image(systemName: active ? "clock.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(active ? AnyShapeStyle(snoozeTint) : AnyShapeStyle(.tertiary))
            }
            .fixedSize()
            .help("Change this later, keeping the current value until then")
        }
    }
}

// ── Small formatting helpers ────────────────────────────────────────────────

private func numeric(_ v: PolicyValue) -> Double {
    if case .number(let d) = v { return d }
    return 0
}

/// The word a person reads for a stored value.
private func word(_ v: PolicyValue) -> String {
    switch v {
    case .number: return v.cli
    case .text(let s):
        switch s {
        case "allow": return "Allow"
        case "block": return "Block"
        case "ask": return "Ask"
        case "warn": return "Warn"
        case "off": return "Off"
        case "enforce": return "Enforce"
        case "encourage": return "Prefer"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }
}

// The panel's shared look, under the names other tabs (Usage, Home) use.
typealias SBStyle = PT
typealias SBGroupHeader = GroupHeader
typealias SBCard = Card
func countdownText(to date: Date, now: Date) -> String { countdown(to: date, now: now) }

private func countdown(to date: Date, now: Date) -> String {
    let s = Int(date.timeIntervalSince(now))
    if s < 60 { return "under a minute" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    return "\(m)m"
}

// ── The menu bar icon that opens the panel ─────────────────────────────────

final class PolicyStatusController: NSObject, NSPopoverDelegate {
    let store = PolicyStore()
    let usage = UsageStore()
    let lights = LightsStore()
    let controls = ControlsStore()
    private var concerns: [SwitchboardConcern] = []
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var ticker: Timer?
    private var peek: HoverPeek?
    private var dot: IconDot?
    private var dotWatch: AnyCancellable?
    /// The hover lines only the app can write (problems, timers, services),
    /// for the items chosen in Settings.
    var appHoverLines: (Set<HoverItem>) -> [HoverLine] = { _ in [] }
    /// Services that are down, by name, for the Now page's chips.
    var appServicesDown: () -> [String] = { [] }
    /// What the hover card shows and which quick page it is on.
    let quick = QuickState()

    /// Fill the Now page's badges.
    func refreshQuick() {
        quick.badges = statusBadges()
    }

    /// One badge per thing that needs the owner, for the hover items chosen in
    /// Settings: what waits, each problem, what is down, running timers.
    func statusBadges() -> [StatusBadge] {
        var out: [StatusBadge] = []
        let chosen = store.hoverItems
        let n = store.needsWaiting
        if chosen.contains(.approvals), n > 0 {
            out.append(StatusBadge(id: "approvals", icon: "hand.raised.fill", text: "\(n) waiting", kind: .waiting,
                                   help: "\(n) push\(n == 1 ? "" : "es") or ask\(n == 1 ? "" : "s") wait on you", opens: .approvals))
        }
        if chosen.contains(.problems) {
            out += problemList.enumerated().map { StatusBadge(problem: $1, index: $0) }
        }
        let down = chosen.contains(.services) ? appServicesDown() : []
        if !down.isEmpty {
            out.append(StatusBadge(id: "down", icon: "bolt.slash.fill", text: "Down: " + down.joined(separator: ", "),
                                   kind: .error, help: "Open Runtime", tab: "runtime"))
        }
        if chosen.contains(.timers) {
            for t in TimerStore.shared.running.prefix(2) {
                out.append(StatusBadge(id: "timer-\(t.id)", icon: Icons.tab["timers"] ?? "timer",
                                       text: "\(t.label.isEmpty ? "Timer" : t.label) · \(clock(t.fireAt.timeIntervalSinceNow))",
                                       kind: .info, help: "Open Timers", tab: "timers"))
            }
        }
        return out
    }

    init(liveDirs: @escaping () -> [String], requestSystemRefresh: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "switchboard"
        store.liveDirs = liveDirs
        store.requestSystemRefresh = requestSystemRefresh
        if let b = item.button {
            b.image = switchboardGlyph()
            b.target = self
            b.action = #selector(toggle(_:))
            // The tooltip would cover the preview; the preview says more.
            b.toolTip = nil
            let card = QuickCard(state: quick, policy: store, usage: usage, lights: lights, notes: NotesStore.shared,
                                 openTab: { [weak self] tab in self?.peek?.hide(); self?.show(tab: tab) },
                                 openSearch: { [weak self] tab, q in
                                     self?.store.queries[tab] = q
                                     self?.peek?.hide(); self?.show(tab: tab)
                                 })
            peek = HoverPeek(button: b, state: quick, card: AnyView(card),
                             refresh: { [weak self] in self?.refreshQuick() },
                             panelOpen: { [weak self] in self?.popover.isShown ?? false })
            let d = IconDot(on: b)
            dot = d
            // One writer for the dot: this and updateDot both go through renderDot,
            // so a change in what waits never erases a red "something is wrong".
            dotWatch = store.$needsWaiting.combineLatest(store.$hoverItems)
                .sink { [weak self] n, items in self?.renderDot(waiting: n, items: items) }
        }
        concerns = SwitchboardConcerns.all(policy: store, usage: usage, lights: lights, controls: controls)
        let host = NSHostingController(rootView: PolicyPanel(concerns: concerns, store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // Pay the first-open costs now, not on the owner's click: load the
        // values and lay out the view once while nobody is waiting.
        store.reload()
        usage.reload()
        host.view.layoutSubtreeIfNeeded()

        // Lets a script or hotkey tool open or close the panel without a click.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.switchboard.toggle"),
            object: nil, queue: .main) { [weak self] _ in self?.toggle(nil) }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        show()
    }

    func show(tab chosen: String? = nil) {
        // Open at once on what is already loaded, then refresh underneath. The
        // values rarely change between opens, and waiting for pol.sh first is
        // what made the click feel slow.
        guard let b = item.button, !popover.isShown else { return }
        peek?.hide()
        // A tab asked for by name (a quick page's Open button) wins; otherwise
        // open on whatever turned the dot red or yellow, once per new cause.
        if let tab = chosen {
            UserDefaults.standard.set(tab, forKey: PolicyPanel.tabKey)
            Visibility.rememberTab(tab)
        } else if let tab = attentionTab() {
            UserDefaults.standard.set(tab, forKey: PolicyPanel.tabKey)
            Visibility.rememberTab(tab)
        }
        // Looking at the panel answers a ringing timer, and picks up a
        // notification setting changed in System Settings.
        TimerStore.shared.silence()
        TimerStore.shared.checkNotifications()
        let t0 = Date()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        dlog("policy panel shown in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        // Every concern refreshes on open: each is cheap or runs in the
        // background (a Codex re-ask only when its cache is stale).
        store.reload()
        // A tab hidden in Settings is never refreshed, so it costs nothing.
        concerns.filter { !store.hiddenTabs.contains($0.id) }.forEach { $0.refresh() }
        // Keep countdowns honest while open, and pick up changes made elsewhere.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.store.reload()
            self?.usage.loadClaude()
        }
    }

    /// The hover preview's lines, in a fixed order: limits, what waits, then
    /// what the app knows. Only the items chosen in Settings.
    func hoverLines() -> [HoverLine] {
        let chosen = store.hoverItems
        var out: [HoverLine] = []
        if chosen.contains(.limits) {
            usage.loadClaude()   // one small file read, so the bars are current
            for w in usage.claude where w.id == "five_hour" || w.id == "seven_day" {
                let color: Color = w.pct >= usage.dangerPct ? .red : w.pct >= usage.warnPct ? .orange : .green
                // The reset time only earns its space when it is close.
                let soon = w.resetsAt.map { $0.timeIntervalSinceNow < 1800 && $0 > Date() } ?? false
                out.append(.bar(label: w.id == "five_hour" ? "5h" : "Week", pct: w.pct, color: color,
                                resets: soon ? "resets in " + countdownText(to: w.resetsAt!, now: Date()) : ""))
            }
        }
        if chosen.contains(.approvals), store.needsWaiting > 0 {
            let first = store.needGroups.first?.rows.first?.label ?? ""
            out.append(.note(icon: "hand.raised.fill",
                             text: "\(store.needsWaiting) waiting on you" + (first.isEmpty ? "" : ": \(first)"),
                             tint: Color(nsColor: menuYellow)))
        }
        if chosen.contains(.timers) {
            // At most two countdowns, soonest first, then the next note reminder.
            for t in TimerStore.shared.running.prefix(2) {
                out.append(.note(icon: Icons.tab["timers"]!, text: "\(t.label) · \(clock(t.fireAt.timeIntervalSinceNow))", tint: timerColor(t.color)))
            }
            if let n = NotesStore.shared.notes.filter({ ($0.remindAt ?? .distantPast) > Date() }).min(by: { $0.remindAt! < $1.remindAt! }) {
                out.append(.note(icon: "bell", text: "\(n.title) · \(WhenText.describe(n.remindAt!))", tint: .secondary))
            }
        }
        return out + appHoverLines(chosen)
    }

    /// The icon dot: red while something is broken, yellow while something waits.
    func updateDot(problems: [Problem]) {
        lastProblems = problems.contains { $0.level == .error }
        problemList = problems
        let levels = Problem.levels(problems)
        if store.problemLevels != levels { store.problemLevels = levels }
        renderDot(waiting: store.needsWaiting, items: store.hoverItems)
    }
    /// Whether any error stands; warnings never turn the icon red.
    private var lastProblems = false
    private var problemList: [Problem] = []
    /// What the panel last jumped to, so an unchanged problem does not pull
    /// the owner away from the tab they chose on every open.
    private var lastAttention = ""

    /// The tab behind the dot: the first problem's tab when it is red, Approvals
    /// when it is yellow. Nil when nothing asks, when it is the same thing the
    /// panel already jumped to, or when that tab is hidden.
    func attentionTab() -> String? {
        let r = Self.attention(problems: problemList, hidden: store.hiddenTabs, waiting: store.needsWaiting,
                               waitingKeys: store.needGroups.flatMap(\.rows).compactMap(\.key), last: lastAttention)
        lastAttention = r.signature
        return r.tab
    }

    /// The decision behind `attentionTab`, without the panel, so a probe can drive it.
    /// Only errors pull the panel to a tab; a warning waits for the owner to look.
    static func attention(problems: [Problem], hidden: Set<String>, waiting: Int,
                          waitingKeys: [String], last: String) -> (tab: String?, signature: String) {
        let visible = problems.filter { $0.level == .error && !hidden.contains($0.tab) }
        if let p = visible.first {
            let sig = "p:" + visible.map(\.text).joined(separator: "|")
            return (sig == last ? nil : p.tab, sig)
        }
        if waiting > 0 {
            let sig = "n:" + waitingKeys.joined(separator: ",")
            return (sig == last ? nil : "approvals", sig)
        }
        return (nil, "")
    }

    /// Takes the values as arguments: a @Published sink fires before the store property changes.
    private func renderDot(waiting n: Int, items: Set<HoverItem>) {
        dot?.show(items.contains(.iconDot) && (lastProblems || n > 0), color: lastProblems ? .systemRed : menuYellow)
    }

    func popoverDidClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
    }
}

// ── The menu bar glyph ─────────────────────────────────────────────────────

/// A bank of three vertical faders: a mixing desk, which reads as "switches
/// and levels" and stays clearly apart from Control Center's stacked toggles.
/// An SF Symbol, so it is hinted for the menu bar at 1x and 2x alike.
func switchboardGlyph() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    let img = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Switchboard")?
        .withSymbolConfiguration(cfg) ?? NSImage()
    img.isTemplate = true
    return img
}

// ── Headless: render the panel to a PNG, in a chosen appearance and scope ──

/// Each list tab's reader, for drawing it offscreen without the panel's refresh.
let catalogReaders: [String: () -> [SystemGroup]] = [
    "library": LibraryCatalog.groups,
    "rules": RulesCatalog.groups,
    "ledger": LedgerCatalog.groups,
    "plugins": PluginsCatalog.groups,
    "queue": QueueCatalog.groups,
]

/// Draws the real panel offscreen, so it can be checked in dark and light
/// without opening anything on the owner's screen. Returns false on failure.
@discardableResult
func snapshotPolicyPanel(to path: String, dark: Bool, scopeDir: String?,
                         tab: String = "agents", system: [SystemGroup] = [], remote: [SystemGroup] = []) -> Bool {
    let store = PolicyStore()
    if let d = scopeDir, let root = PolicyCLI.root(of: d) { store.scope = .project(root) }
    let r = PolicyCLI.load(store.scope)
    store.applyForSnapshot(items: r.items, projects: r.projects, error: r.error)
    store.systemGroups = system
    store.remoteGroups = remote
    if let read = catalogReaders[tab] { store.catalogs[tab] = read() }
    if tab == "timers", CommandLine.arguments.contains("--demo-states"), TimerStore.shared.timers.isEmpty {
        TimerStore.shared.add(label: "Tea", color: "green", fireAt: Date().addingTimeInterval(245))
        TimerStore.shared.add(label: "Stand-up", color: "purple", fireAt: Date().addingTimeInterval(1800))
    }
    if tab == "notes" { NotesStore.remindersOff = true; NotesStore.shared.load(); NoteRow.startOpen = CommandLine.arguments.contains("--expand"); NoteCompose.startExpanded = NoteRow.startOpen }
    if let f = CommandLine.arguments.firstIndex(of: "--filter").flatMap({ $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }) {
        store.queries[tab + "::scope"] = f
    }
    if let m = CommandLine.arguments.firstIndex(of: "--problem-tabs").flatMap({ $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }) {
        // tab or tab:warn, comma separated
        store.problemLevels = Dictionary(m.split(separator: ",").map { part -> (String, ProblemLevel) in
            let bits = part.split(separator: ":")
            return (String(bits[0]), bits.count > 1 && bits[1] == "warn" ? .warn : .error)
        }, uniquingKeysWith: max)
    }
    if let q = CommandLine.arguments.firstIndex(of: "--query").flatMap({ $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }) { store.queries[tab] = q }
    var needs = NeedsYou.items()
    if CommandLine.arguments.contains("--demo-states") {
        var push = NeedItem(id: "demo-push", kind: .push, title: "Push switchboard-mac",
                            sessionID: "demo", sessionDir: NSHomeDirectory() + "/Code/Claude/switchboard-mac",
                            since: Date().addingTimeInterval(-240), approveLine: "approve push 0000demo", files: [])
        push.approvedFile = NSTemporaryDirectory() + "sb-demo-never-written"
        push.details = [("Repository", "~/Code/Claude/switchboard-mac"), ("Why it is held", "push targets main"),
                        ("Session", "demo"), ("Approve line", "approve push 0000demo"), ("Cancel line", "cancel push")]
        needs.append(push)
        needs.append(NeedItem(id: "demo-ask", kind: .ask, title: "Posting to Slack",
                              sessionID: "gone", sessionDir: nil, since: Date().addingTimeInterval(-7200),
                              approveLine: "approve slack.post 1111demo", files: []))
    }
    store.setNeeds(needs) {}
    let usage = UsageStore()
    let lights = LightsStore()
    if tab == "usage" { usage.reload() }   // file reads only; never starts Codex
    if tab == "home" { lights.loadForSnapshot() }
    let controls = ControlsStore()
    // Paired Bluetooth devices would raise a permission prompt; a snapshot never does.
    if tab == "controls" { controls.load(devices: false) }
    // --demo-states plants one failure per tab so their look can be checked.
    if CommandLine.arguments.contains("--demo-states") {
        if let k = store.items.first(where: { $0.kind == .toggle })?.key {
            store.failures[k] = "pol.sh: invalid value (demo failure)"
        }
        if let b = lights.bulbs.first {
            lights.failures[b.mac] = LightsStore.plain("bulb did not confirm the change")
        }
        usage.demoRefreshFailure("Codex did not answer within 20s (demo failure)")
    }
    let concerns = SwitchboardConcerns.all(policy: store, usage: usage, lights: lights, controls: controls)

    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    // "scopes" renders the scope picker's list on its own; a popover cannot be
    // drawn offscreen, so this is how its rows get checked.
    let root: AnyView = tab == "scopes"
        ? AnyView(VStack(alignment: .leading, spacing: 0) {
              ForEach(store.scopes, id: \.self) { s in ScopeRow(scope: s, selected: s == store.scope) {} }
          }.padding(6).frame(width: 300))
        : AnyView(PolicyPanel(concerns: concerns, store: store, unbounded: true, forcedTab: tab))
    let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.safeAreaRegions = []
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = appearance
    win.backgroundColor = .windowBackgroundColor
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

/// A search field with an Everywhere / One project filter beside it, for a
/// list whose sections split by where they apply.
struct ScopedSearch: View {
    @ObservedObject var store: PolicyStore
    let id: String
    let prompt: String

    var body: some View {
        // SearchField brings its own outer padding; the picker matches its edges.
        VStack(spacing: 4) {
            SearchField(text: Binding(get: { store.queries[id] ?? "" }, set: { store.queries[id] = $0 }), prompt: prompt)
            Picker("", selection: Binding(get: { store.queries[id + "::scope"] ?? "all" },
                                          set: { store.queries[id + "::scope"] = $0 })) {
                Text("All").tag("all")
                Text("Everywhere").tag("everywhere")
                Text("One project").tag("project")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, PT.gap)
        }
    }
}

// ── A search field pinned above a list ──────────────────────────────────────

/// A search field in the panel's own look: the rounded fill of the tab bar,
/// a magnifying glass, and a clear button once there is text.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool
    /// What is typed; handed to `text` once typing pauses for 250 ms.
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            // one word; the tab already says what is being searched, and the tooltip says it in full
            TextField("Search", text: $draft)
                .textFieldStyle(.plain).font(PT.label)
                .focused($focused)
                .help(prompt)
                // Escape lets go of the keyboard and keeps the search; the x clears it
                .onExitCommand { focused = false }
                .onAppear { draft = text }
                .task(id: draft) {
                    // Cancelled and restarted by every keystroke, so only a pause lands.
                    if draft.isEmpty { text = ""; return }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Task.isCancelled { text = draft }
                }
            if !draft.isEmpty {
                Button { draft = ""; text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Clear")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear))
        .padding(.horizontal, PT.gap).padding(.top, PT.gap - 2).padding(.bottom, 2)
        // A menu bar app takes keystrokes only once it is active.
        .onTapGesture { NSApp.activate(ignoringOtherApps: true); focused = true }
    }
}
