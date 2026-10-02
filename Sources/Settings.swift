// Settings.swift
// The Settings tab: which tabs and sections the panel shows, and what the
// hover preview on the menu bar icon carries. A hidden tab or section is
// neither drawn nor read (see Visibility in AppSupport.swift).

import AppKit
import SwiftUI

struct SettingsTab: Identifiable { let id: String; let title: String; let icon: String }

struct SettingsTabView: View {
    @ObservedObject var store: PolicyStore
    /// Tab ids and names in bar order, Settings itself left out.
    let tabs: [(id: String, title: String, icon: String)]

    private var query: String { (store.queries["settings"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    private func matches(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }

    /// Tabs in the owner's order, with those the search leaves out removed.
    private var orderedTabs: [SettingsTab] {
        let rank = Dictionary(store.tabOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return tabs.map { SettingsTab(id: $0.id, title: $0.title, icon: $0.icon) }
            .sorted { (rank[$0.id] ?? 99) < (rank[$1.id] ?? 99) }
            .filter { t in matches(t.title) || (Visibility.sections[t.id] ?? []).contains(where: matches) }
    }

    var body: some View {
        // a search for "hover" (what the hover card's settings button opens) shows all of the hover's settings
        let hoverAll = matches("hover")
        let hover = HoverItem.allCases.filter { hoverAll || matches($0.title) || matches($0.detail) }
        let pages = quickPages.filter { hoverAll || matches($0.title) }
        let linger = hoverAll || matches("delay") || matches("away") || matches("linger")
        let folder = matches("notes folder") || matches(NotesStore.dir)
        let sizes = matches("size") || matches("small") || matches("medium") || matches("large") || matches("zoom")
        let prompts = matches("permission") || matches("prompt") || matches("claude asks") || matches("approvals")
        VStack(alignment: .leading, spacing: PT.gap) {
            if sizes {
                group("Size", note: "How big everything is drawn: the panel, the hover card, its pages and the menu bar icon. Text grows most, icons a little less, inputs least.",
                      rows: [sizeRow])
            }
            if !orderedTabs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        GroupHeader(name: "Tabs")
                        Spacer()
                        if query.isEmpty && store.tabOrder != Visibility.defaultTabOrder {
                            Button("Default order") { store.tabOrder = Visibility.defaultTabOrder }
                                .buttonStyle(.link).font(PT.caption)
                                .help("Put the tabs back in the default order")
                        }
                    }
                    note(query.isEmpty ? "Drag the grip to change a tab's place within its space. Open a tab to choose its sections; hidden ones are not read at all."
                                       : "Matching tabs, opened to the matching sections.")
                    ForEach(Visibility.spaces, id: \.id) { s in
                        let inSpace = orderedTabs.filter { s.tabs.contains($0.id) }
                        if !inSpace.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: s.icon).font(.sbIcon(9.5))
                                Text(s.title).font(PT.caption)
                            }
                            .foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 2)
                            Card {
                                // Dragging stays inside a space: a tab's space is fixed.
                                ReorderStack(items: inSpace, move: { d, t in
                                    if s.tabs.contains(d) { store.moveTab(d, to: t) }
                                }) { i, t, grip in
                                    VStack(spacing: 0) {
                                        if i > 0 { Divider().padding(.leading, PT.rowH) }
                                        HStack(spacing: 0) {
                                            if query.isEmpty && inSpace.count > 1 { grip.padding(.leading, 6) }
                                            SystemRowView(row: tabRow(t), store: store)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !pages.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: "Hover pages")
                    note(query.isEmpty ? "The pages the hover card moves through, in this order. Drag the grip to reorder; the switch hides a page."
                                       : "Matching hover pages.")
                    Card {
                        ReorderStack(items: pages, move: { d, t in
                            store.quickPageOrder = reordered(store.quickPageOrder, moving: d, to: t)
                        }) { i, p, grip in
                            VStack(spacing: 0) {
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                HStack(spacing: 0) {
                                    if query.isEmpty { grip.padding(.leading, 6) }
                                    SystemRowView(row: pageRow(p), store: store)
                                }
                            }
                        }
                    }
                }
            }
            if hoverAll || matches("approvals") || matches("waiting") {
                group("Under every page", note: "What waits on you as a small card under whichever hover page is showing, one line each, with a button to the Approvals page.",
                      rows: [approvalsCardRow])
            }
            if linger {
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: "Mouse-away delay")
                    note("How long the hover card stays after the pointer leaves the icon and the card.")
                    Card { lingerSlider }
                }
            }
            if !hover.isEmpty {
                group("Now page", note: "What the Now hover page shows as badges under its shortcuts, and the dot on the menu bar icon.",
                      rows: hover.map(hoverRow))
            }
            if folder {
                group("Notes folder", note: "Where each note is saved as a markdown file.", rows: [notesFolderRow])
            }
            if prompts {
                group("Claude's permission prompts",
                      note: "When on, a prompt Claude Code would ask in the terminal shows under Claude asks in Approvals first. It waits \(PermissionRoute.wait) seconds for your Approve or Deny there, then asks in the terminal as usual.",
                      rows: [promptsRow])
            }
            if orderedTabs.isEmpty && hover.isEmpty && pages.isEmpty && !linger && !folder && !prompts && !sizes {
                Text("Nothing in Settings matches \"\(query)\".").font(PT.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(PT.gap)
    }

    @ObservedObject private var scale = UIScale.shared

    private var approvalsCardRow: SystemRow {
        var r = SystemRow(label: "Show what waits under every page", state: store.approvalsUnderEveryPage ? .on(menuGreen) : .off,
                          note: store.approvalsUnderEveryPage ? "on" : "off", tip: "",
                          action: { store.approvalsUnderEveryPage.toggle() })
        r.icon = "hand.raised"
        r.key = "settings-approvals-card"
        return r
    }

    private var sizeRow: SystemRow {
        var r = SystemRow(label: scale.size.title, state: .ok, note: scale.size.detail, tip: "Small, Medium or Large")
        r.icon = "textformat.size"
        r.choices = UISize.allCases.map(\.title)
        r.selected = UISize.allCases.firstIndex(of: scale.size) ?? 0
        r.onChoose = { i in scale.size = UISize.allCases[i] }
        r.key = "settings-size"
        return r
    }

    @State private var promptsOn = PermissionRoute.isOn
    @State private var promptsError: String?

    private var promptsRow: SystemRow {
        var r = SystemRow(label: "Answer them in Switchboard", state: promptsOn ? .on(menuGreen) : .off,
                          note: promptsError.map { "couldn't switch: \($0)" } ?? (promptsOn ? "on: prompts wait here first" : "off: the terminal asks, as usual"),
                          tip: "Holds each Claude Code permission prompt for up to \(PermissionRoute.wait) s so you can answer it from Approvals.",
                          action: {
                              promptsError = PermissionRoute.set(!promptsOn)
                              promptsOn = PermissionRoute.isOn
                          })
        r.icon = "hand.raised"
        r.key = "settings-permission-route"
        return r
    }

    private func note(_ text: String) -> some View {
        Text(text).font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group(_ title: String, note text: String, rows: [SystemRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: title)
            note(text)
            Card {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    SystemRowView(row: row, store: store)
                }
            }
        }
    }

    /// A tab opens to "Show this tab" and one switch per section it has.
    /// While searching, only matching sections are listed and the tab opens.
    private func tabRow(_ t: SettingsTab) -> SystemRow {
        let tabOn = !store.hiddenTabs.contains(t.id)
        let sections = Visibility.sections[t.id] ?? []
        let hiddenHere = sections.filter { store.hiddenSections.contains(t.id + "::" + $0) }.count
        let note = !tabOn ? "hidden" : sections.isEmpty ? "shown"
            : hiddenHere == 0 ? (sections.count == 1 ? "its section shown" : "all \(sections.count) sections shown")
            : "\(sections.count - hiddenHere) of \(sections.count) sections shown"
        var r = SystemRow(label: t.title, state: tabOn ? .on(menuGreen) : .off, note: note, tip: "")
        r.icon = t.icon
        // A new key while searching makes the row open fresh on its matches.
        r.key = "settings-tab-" + t.id + (query.isEmpty ? "" : "-q")
        r.startsOpen = !query.isEmpty && !matches(t.title)
        var show = SystemRow(label: "Show this tab", state: tabOn ? .on(menuGreen) : .off, note: "", tip: "",
                             action: { toggle(&store.hiddenTabs, t.id) })
        show.icon = "eye"
        show.key = r.key! + "-show"
        let listed = matches(t.title) ? sections : sections.filter(matches)
        r.children = [show] + listed.map { s in
            let key = t.id + "::" + s
            var c = SystemRow(label: s, state: store.hiddenSections.contains(key) ? .off : .on(menuGreen),
                              note: "", enabled: tabOn, tip: "", action: {
                                  toggle(&store.hiddenSections, key)
                                  // A section coming back was never read while hidden: read it on the next visit.
                                  if !store.hiddenSections.contains(key) { store.catalogs[t.id] = nil }
                                  store.requestSystemRefresh()
                              })
            c.key = "settings-section-" + key
            c.icon = Icons.section[s]
            return c
        }
        return r
    }

    /// The standard macOS slider: one-second ticks, its ends labelled, the value read out beside it,
    /// and scrolling over it steps a second at a time like the panel's other sliders.
    private var lingerSlider: some View {
        HStack(spacing: 10) {
            Slider(value: $store.hoverLinger, in: PolicyStore.hoverLingerRange, step: 1) {
                Text("Mouse-away delay")
            } minimumValueLabel: {
                Text("1 s").font(PT.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("15 s").font(PT.caption).foregroundStyle(.secondary)
            }
            .labelsHidden().sbControlSize(.small)
            Text("\(Int(store.hoverLinger)) s").font(PT.label.monospacedDigit()).frame(width: sw(34), alignment: .trailing)
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, PT.rowV + 2)
        .scrollSteps("settings.linger", inContent: true, stepper: .slider()) { by in
            store.hoverLinger = PolicyStore.clampedLinger(store.hoverLinger - Double(by))
        }
    }

    /// Every hover page in the owner's order, shown or not.
    private var quickPages: [SettingsTab] {
        store.quickPageOrder.compactMap(QuickPage.init(rawValue:)).map { SettingsTab(id: $0.rawValue, title: $0.title, icon: $0.icon) }
    }

    /// A page's switch; the last page shown cannot be hidden, so the card always has one.
    private func pageRow(_ p: SettingsTab) -> SystemRow {
        let on = !store.hiddenQuickPages.contains(p.id)
        let last = on && store.shownQuickPages == [p.id]
        var r = SystemRow(label: p.title, state: on ? .on(menuGreen) : .off,
                          note: last ? "the only page shown" : "", enabled: !last, tip: "",
                          action: { if !last { toggle(&store.hiddenQuickPages, p.id) } })
        r.icon = p.icon
        r.key = "settings-page-" + p.id
        return r
    }

    private func hoverRow(_ item: HoverItem) -> SystemRow {
        var r = SystemRow(label: item.title, state: store.hoverItems.contains(item) ? .on(menuGreen) : .off,
                          note: item.detail, tip: "", action: {
                              if store.hoverItems.contains(item) { store.hoverItems.remove(item) } else { store.hoverItems.insert(item) }
                          })
        r.key = "settings-hover-" + item.rawValue
        return r
    }

    /// Choose a folder for notes; existing notes stay where they are, so a
    /// move is a Finder job the owner does on purpose.
    private var notesFolderRow: SystemRow {
        let custom = UserDefaults.standard.string(forKey: NotesStore.folderKey)?.isEmpty == false
        var r = SystemRow(label: abbreviateHome(NotesStore.dir), state: .off,
                          note: custom ? "chosen by you; notes already saved elsewhere stay there" : "the default", tip: "")
        r.key = "settings-notes-folder"
        r.showsBadge = false
        r.buttons = [RowButton(label: "Choose", kind: .run({
            DispatchQueue.main.async {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                p.prompt = "Use this folder"
                NSApp.activate(ignoringOtherApps: true)
                if p.runModal() == .OK, let url = p.url {
                    UserDefaults.standard.set(url.path, forKey: NotesStore.folderKey)
                    NotesStore.shared.load()
                    store.objectWillChange.send()
                }
            }
            return nil
        }), help: "Choose another folder for notes", icon: "folder.badge.gearshape")]
        if custom {
            r.buttons.append(RowButton(label: "Reset", kind: .run({
                DispatchQueue.main.async {
                    UserDefaults.standard.removeObject(forKey: NotesStore.folderKey)
                    NotesStore.shared.load()
                    store.objectWillChange.send()
                }
                return nil
            }), help: "Go back to the default folder", icon: "arrow.uturn.backward"))
        }
        return r
    }

    private func toggle(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }
}
