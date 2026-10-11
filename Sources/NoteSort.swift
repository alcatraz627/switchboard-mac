// NoteSort.swift
// How the notes list is ordered: the owner's own order, or by date or name.
// A date or name order is a view only; the saved manual order is never touched.

import Foundation

enum NoteSort: String, CaseIterable, Identifiable {
    case manual, newest, oldest, edited, title
    var id: String { rawValue }

    static let key = "switchboard.notes.sort"
    static var saved: NoteSort { NoteSort(rawValue: NotesStore.defaults.string(forKey: key) ?? "") ?? .manual }

    var label: String {
        switch self {
        case .manual: return "My order"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .edited: return "Recently edited"
        case .title: return "A to Z"
        }
    }
    var icon: String {
        switch self {
        case .manual: return "line.3.horizontal"
        case .newest: return "calendar.badge.plus"
        case .oldest: return "calendar"
        case .edited: return "pencil.line"
        case .title: return "textformat.abc"
        }
    }

    /// The notes in this order. Pinned notes stay on top in every order; manual keeps the list as given.
    func apply(_ notes: [Note]) -> [Note] {
        guard self != .manual else { return notes }
        let edits: [String: Date] = self == .edited ? Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.modified ?? $0.created) }) : [:]
        func before(_ a: Note, _ b: Note) -> Bool {
            if a.pinned != b.pinned { return a.pinned }
            switch self {
            case .manual: return false
            case .newest: return a.created > b.created
            case .oldest: return a.created < b.created
            case .edited: return (edits[a.id] ?? .distantPast) > (edits[b.id] ?? .distantPast)
            case .title: return a.heading.localizedStandardCompare(b.heading) == .orderedAscending
            }
        }
        // a stable sort: notes that tie keep the order they came in
        return notes.enumerated().sorted { l, r in
            before(l.element, r.element) ? true : before(r.element, l.element) ? false : l.offset < r.offset
        }.map(\.element)
    }
}

extension Array where Element == Note {
    /// Every tag in use with how many notes carry it, most used first, then by name.
    var tagCounts: [(tag: String, count: Int)] {
        var c: [String: Int] = [:]
        for n in self { for t in n.tags { c[t, default: 0] += 1 } }
        return c.map { (tag: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}
