// SubTabs.swift
// The one sub-tab strip: a row of pills, an icon left of each word, the chosen
// one tinted with the accent. The panel's tab row under the spaces bar and
// Settings' own sections both draw it, so a sub-tab looks the same everywhere.

import SwiftUI

struct SubTabItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    var help = ""
    /// Waiting-on-you count, drawn after the word.
    var badge: Int?
    /// Something wrong on the tab, drawn as a dot after the word when there is no badge.
    var problem: ProblemLevel?
}

struct SubTabStrip: View {
    let items: [SubTabItem]
    let selected: String
    /// Whether the keyboard is on this strip; the chosen pill is then ringed.
    var ringed = false
    let pick: (String) -> Void

    var body: some View {
        // too many for the width: the unchosen pills drop to their icons, the chosen one keeps its word
        ViewThatFits(in: .horizontal) { row(named: true); row(named: false) }
    }

    private func row(named: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { s in
                let on = s.id == selected
                Button { pick(s.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.icon).font(.sbIcon(10.5))
                        if named || on { Text(s.title).font(.sb(11.5, weight: on ? .semibold : .regular)).lineLimit(1) }
                        if let n = s.badge { TabBadge(count: n, onAccent: false) }
                        else if let l = s.problem { ProblemMark(level: l) }
                    }
                    .fixedSize()
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyRing(ringed && on, radius: 7)
                .help(s.help.isEmpty ? s.title : s.help)
            }
            Spacer(minLength: 0)
        }
    }
}
