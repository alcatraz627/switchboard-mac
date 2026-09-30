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
        let hover = HoverItem.allCases.filter { matches($0.title) || matches($0.detail) }
        let folder = matches("notes folder") || matches(NotesStore.dir)
        VStack(alignment: .leading, spacing: PT.gap) {
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
                                Image(systemName: s.icon).font(.system(size: 9.5))
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
            if !hover.isEmpty {
                group("Hover preview", note: "What shows when the pointer rests on the menu bar icon. Keep it short.",
                      rows: hover.map(hoverRow))
            }
            if folder {
                group("Notes folder", note: "Where each note is saved as a markdown file.", rows: [notesFolderRow])
            }
            if orderedTabs.isEmpty && hover.isEmpty && !folder {
                Text("Nothing in Settings matches \"\(query)\".").font(PT.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(PT.gap)
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
