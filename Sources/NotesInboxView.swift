// NotesInboxView.swift
// The inbox above the Notes list: what arrived from another device since it was last looked at, with its three
// exits (keep, done, later), and a folded lane for what agents wrote.

import SwiftUI

/// The times Later offers, from `now`: an hour, tomorrow at nine, next Monday at nine.
enum InboxLater {
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, date: Date)] {
        var nine = calendar.dateComponents([.year, .month, .day], from: now); nine.hour = 9; nine.minute = 0
        let today9 = calendar.date(from: nine) ?? now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today9) ?? now.addingTimeInterval(86_400)
        let daysToMonday = (9 - calendar.component(.weekday, from: now)) % 7
        let monday = calendar.date(byAdding: .day, value: daysToMonday == 0 ? 7 : daysToMonday, to: today9) ?? now.addingTimeInterval(7 * 86_400)
        return [("In an hour", now.addingTimeInterval(3600)), ("Tomorrow morning", tomorrow), ("Next week", monday)]
    }
}

struct InboxSection: View {
    @ObservedObject var inbox = NotesInbox.shared
    @ObservedObject var nav: NotesNav
    /// Snapshots draw the lane open.
    static var startLaneOpen = false
    private var showLane: Bool { nav.laneOpen || Self.startLaneOpen }

    var body: some View {
        let mine = inbox.waiting(), agents = inbox.lane()
        if !mine.isEmpty || !agents.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if !mine.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down").font(.sbIcon(9.5))
                        Text("Inbox \(mine.count)").font(PT.section)
                        Text("arrived from another device").font(PT.caption).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary).padding(.leading, 4)
                    Card {
                        ForEach(Array(mine.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            InboxRow(item: item, nav: nav, inbox: inbox)
                        }
                    }
                }
                if !agents.isEmpty {
                    Button { withAnimation(Motion.slow) { nav.laneOpen.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.sbIcon(8, weight: .semibold)).rotationEffect(.degrees(showLane ? 90 : 0))
                            Image(systemName: "cpu").font(.sbIcon(9.5))
                            Text("From agents \(agents.count)").font(PT.section)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.leading, 4)
                    .help("Notes agents wrote. They stay out of your own list until you keep one.")
                    if showLane {
                        Card {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { i, item in
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                InboxRow(item: item, nav: nav, inbox: inbox)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct InboxRow: View {
    let item: NotesInbox.Item
    @ObservedObject var nav: NotesNav
    let inbox: NotesInbox

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.agent != nil ? "cpu" : item.isBulk ? "tray.full" : item.isSave ? "link" : "note.text").font(.sbIcon(11))
                .foregroundStyle(.secondary).frame(width: si(16))
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(PT.label).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(PT.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(item.isBulk ? "They are in your list, newest first" : item.isSave ? "Open the link" : "Open the note")
            Button { inbox.keep(item.id) } label: { Image(systemName: "checkmark").font(.sbIcon(11)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(item.isBulk ? "Got it: clear this line" : item.isSave ? "Keep it in Saved" : "Keep it in your notes")
            if !item.isBulk {
                Button { inbox.done(item.id) } label: { Image(systemName: "archivebox").font(.sbIcon(11)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(item.isSave ? "Done: remove this save (its history stays)" : "Done: put it away under Expired")
            }
            Menu {
                ForEach(InboxLater.choices(), id: \.title) { c in Button(c.title) { inbox.later(item.id, until: c.date) } }
            } label: { Image(systemName: "clock").font(.sbIcon(11)) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                .help("Later: it comes back in the inbox at the time you pick")
        }
        .padding(.horizontal, PT.rowH - 4).padding(.vertical, 6)
        .keyRing(nav.focus == .inbox(item.id))
        .id("inbox-" + item.id)
        .help("I enters the inbox from the list. K keeps, D puts away, L brings it back tomorrow morning, Return opens.")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let a = item.agent { parts.append("the \(a) agent") } else if let f = item.from { parts.append("from " + f) }
        if item.isBulk { parts.append("too many to list one by one") }
        parts.append(age(item.at))
        return parts.joined(separator: " · ")
    }

    private func open() {
        if item.isBulk { return }
        if item.isSave {
            if let n = SavedStore.shared.items.first(where: { $0.id == String(item.id.dropFirst(7)) }) ?? SavedStore.readAll().first(where: { $0.id == String(item.id.dropFirst(7)) }) {
                SavedStore.shared.open(n)
            }
        } else {
            nav.focus = .open(item.id, nil, typing: false)
        }
    }
}
