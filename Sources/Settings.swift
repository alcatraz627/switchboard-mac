// Settings.swift
// The Settings tab: which tabs and sections the panel shows, and what the
// hover preview on the menu bar icon carries. A hidden tab or section is
// neither drawn nor read (see Visibility in AppSupport.swift).

import AppKit
import SwiftUI

struct SettingsTabView: View {
    @ObservedObject var store: PolicyStore
    /// Tab ids and names in bar order, Settings itself left out.
    let tabs: [(id: String, title: String, icon: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            group("Tabs", note: "Open a tab to choose its sections. Hidden ones are not read at all.", rows: tabs.map(tabRow))
            group("Hover preview", note: "What shows when the pointer rests on the menu bar icon. Keep it short.",
                  rows: HoverItem.allCases.map(hoverRow))
        }
        .padding(PT.gap)
    }

    private func group(_ title: String, note: String, rows: [SystemRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: title)
            Text(note).font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    SystemRowView(row: row, store: store)
                }
            }
        }
    }

    /// A tab opens to "Show this tab" and one switch per section it has.
    private func tabRow(_ t: (id: String, title: String, icon: String)) -> SystemRow {
        let tabOn = !store.hiddenTabs.contains(t.id)
        let sections = Visibility.sections[t.id] ?? []
        let hiddenHere = sections.filter { store.hiddenSections.contains(t.id + "::" + $0) }.count
        let note = !tabOn ? "hidden" : sections.isEmpty ? "shown"
            : hiddenHere == 0 ? (sections.count == 1 ? "its section shown" : "all \(sections.count) sections shown")
            : "\(sections.count - hiddenHere) of \(sections.count) sections shown"
        var r = SystemRow(label: t.title, state: tabOn ? .on(menuGreen) : .off, note: note, tip: "")
        r.key = "settings-tab-" + t.id
        var show = SystemRow(label: "Show this tab", state: tabOn ? .on(menuGreen) : .off, note: "", tip: "",
                             action: { toggle(&store.hiddenTabs, t.id) })
        show.key = r.key! + "-show"
        r.children = [show] + sections.map { s in
            let key = t.id + "::" + s
            var c = SystemRow(label: s, state: store.hiddenSections.contains(key) ? .off : .on(menuGreen),
                              note: "", enabled: tabOn, tip: "", action: {
                                  toggle(&store.hiddenSections, key)
                                  // A section coming back was never read while hidden: read it on the next visit.
                                  if !store.hiddenSections.contains(key) { store.catalogs[t.id] = nil }
                                  store.requestSystemRefresh()
                              })
            c.key = "settings-section-" + key
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

    private func toggle(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }
}
