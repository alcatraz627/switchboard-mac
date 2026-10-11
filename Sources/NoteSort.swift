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

/// A note's `pos`: a bare base-36 string, smaller sits higher. Same maths as the Pi (specs/order.md),
/// so a key made here sorts the same there.
enum NotePos {
    static let alpha = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// 1 to 32 characters of 0-9a-z, never ending in 0. Anything else still sorts by its bytes
    /// but is never used as a bound when a new key is made.
    static func usable(_ s: String?) -> Bool {
        guard let s, !s.isEmpty, s.utf8.count <= 32, s.last != "0" else { return false }
        return s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }
    }

    private static func digit(_ c: Character) -> Int { alpha.firstIndex(of: c) ?? 0 }

    /// A key strictly between `a` ("" for no lower bound) and `b` (nil for no upper bound).
    static func between(_ a: String, _ b: String?) -> String {
        let lo = Array(a), hi = b.map(Array.init)
        var out = "", i = 0, bounded = hi != nil
        while true {
            let l = i < lo.count ? digit(lo[i]) : 0
            let h = bounded && i < hi!.count ? digit(hi![i]) : 36
            if h - l > 1 { return out + String(alpha[(l + h) / 2]) }
            out.append(alpha[l])
            if bounded && h != l { bounded = false }
            i += 1
        }
    }

    /// n well-separated keys in order, for arranging a never-arranged group once.
    static func spread(_ n: Int) -> [String] {
        guard n > 0 else { return [] }
        let step = 46656 / (n + 1)
        return (1...n).map { k in
            var v = k * step, digits = ""
            while v > 0 { digits = String(alpha[v % 36]) + digits; v /= 36 }
            digits = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
            while digits.last == "0" { digits.removeLast() }
            return digits
        }
    }

    /// `count` ascending keys that all sit above `below` (nil: no limit).
    static func fresh(_ count: Int, below: String?) -> [String] {
        guard let below else { return spread(count) }
        func halves(_ lo: String, _ hi: String, _ n: Int) -> [String] {
            if n == 0 { return [] }
            let key = between(lo, hi), left = n / 2
            return halves(lo, key, left) + [key] + halves(key, hi, n - left - 1)
        }
        return halves("", below, count)
    }
}

/// The one list order every surface shows: pinned first, never-arranged above arranged
/// (newest first among them), arranged by `pos` in byte order, then by id.
enum NoteOrder {
    static func before(_ a: Note, _ b: Note) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        switch (a.pos, b.pos) {
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil):
            // whole seconds, as the file and the Pi keep them
            let x = a.created.timeIntervalSince1970.rounded(.down), y = b.created.timeIntervalSince1970.rounded(.down)
            if x != y { return x > y }
        case (let p?, let q?):
            if p != q { return p.utf8.lexicographicallyPrecedes(q.utf8) }
        }
        return a.id < b.id
    }

    static func sorted(_ notes: [Note]) -> [Note] { notes.sorted(by: before) }
}

extension Array where Element == Note {
    /// Every tag in use with how many notes carry it, most used first, then by name.
    var tagCounts: [(tag: String, count: Int)] {
        var c: [String: Int] = [:]
        for n in self { for t in n.tags { c[t, default: 0] += 1 } }
        return c.map { (tag: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}
