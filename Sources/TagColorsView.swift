// TagColorsView.swift
// Settings page for tags: every tag in use on a note or a save, with its colour and its name. Colours are
// written to `.meta/tags.json`, which every app reads, so a tag looks the same on each device. Renaming a tag
// renames it on every note and save that carries it.

import SwiftUI

/// A row of tags as small chips, each with its colour from `.meta/tags.json` as a dot; one line, cut at the edge.
/// Lays its children out left to right on one line and leaves out the ones that do not fit, so a long list of tags never
/// widens the row it sits in.
struct OneLine: Layout {
    var spacing: CGFloat = 4

    private func fitted(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (width: CGFloat, height: CGFloat, count: Int) {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, h: CGFloat = 0, n = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            let next = x + (n > 0 ? spacing : 0) + sz.width
            if next > limit { break }
            x = next; h = max(h, sz.height); n += 1
        }
        return (x, h, n)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let f = fitted(proposal, subviews)
        return CGSize(width: f.width, height: f.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = fitted(proposal, subviews)
        var x = bounds.minX
        for (i, s) in subviews.enumerated() {
            let sz = s.sizeThatFits(.unspecified)
            if i < f.count { s.place(at: CGPoint(x: x, y: bounds.minY), proposal: .unspecified); x += sz.width + spacing }
            else { s.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .unspecified) }
        }
    }
}

struct TagChips: View {
    let tags: [String]
    var body: some View {
        OneLine(spacing: 4) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) {
                    if let c = TagColors.forTag(t) { Circle().fill(c).frame(width: 6, height: 6) }
                    Text("#" + t).font(.sb(10)).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.07)))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).clipped()
        .help(tags.map { "#" + $0 }.joined(separator: " "))
    }
}

enum TagRename {
    /// Renames `old` to `new` on every note and save, and carries its colour over. Returns how many files changed.
    @discardableResult
    static func run(_ old: String, to rawNew: String, notes: NotesStore = .shared, saved: SavedStore = .shared) -> Int {
        let new = rawNew.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !new.isEmpty, new != old else { return 0 }
        var changed = 0
        func swapped(_ tags: [String]) -> [String] { tags.map { $0 == old ? new : $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        // saves are read from the folder first, whether or not the Saved tab was ever opened this run, and each file is
        // changed as it is on disk now, only in its tags
        saved.load()
        for n in notes.notes where n.tags.contains(old) {
            if notes.patch(n.id, reason: "tag renamed", { $0.tags = swapped($0.tags) }) { changed += 1 }
        }
        for s in saved.items where s.tags.contains(old) {
            if saved.patch(s.id, { $0.tags = swapped($0.tags) }) { changed += 1 }
        }
        if let c = TagColors.read()[old] { TagColors.set(new, to: TagColors.read()[new] ?? c); TagColors.set(old, to: nil) }
        return changed
    }
}

struct TagColorsEditor: View {
    @ObservedObject var notes: NotesStore = .shared
    @ObservedObject var saved: SavedStore = .shared
    @State private var colours = TagColors.read()
    @State private var drafts: [String: String] = [:]

    /// Every tag on a note or save, plus any that only has a colour, with how many carry it.
    private var rows: [(tag: String, count: Int)] {
        var c: [String: Int] = [:]
        for n in notes.notes { for t in n.tags { c[t, default: 0] += 1 } }
        for s in saved.items { for t in s.tags { c[t, default: 0] += 1 } }
        for t in colours.keys where c[t] == nil { c[t] = 0 }
        return c.map { (tag: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: "Tag colours")
            Text("A tag's colour is kept in the notes folder, so it looks the same on the phone. Renaming changes it on every note and save.")
                .font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            Card {
                if rows.isEmpty {
                    Text("No tags yet. Tag a note or a save and it shows up here.").font(PT.caption).foregroundStyle(.secondary).padding(10)
                }
                ForEach(Array(rows.enumerated()), id: \.element.tag) { i, r in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    HStack(spacing: 8) {
                        swatch(r.tag)
                        TextField("name", text: Binding(get: { drafts[r.tag] ?? r.tag }, set: { drafts[r.tag] = $0 }))
                            .textFieldStyle(.plain).font(PT.label).inputBox(focused: false)
                            .onSubmit { commit(r.tag) }
                        Text("\(r.count) \(r.count == 1 ? "item" : "items")").font(PT.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, PT.rowH - 4).padding(.vertical, 5)
                }
            }
        }
    }

    private func swatch(_ tag: String) -> some View {
        let current = colours[tag].flatMap(TagColors.color)
        return Menu {
            ForEach(Array(NoteSpec.colors).sorted(), id: \.self) { name in
                Button { set(tag, name) } label: { Label(name.capitalized, systemImage: colours[tag] == name ? "checkmark" : "circle.fill") }
            }
            Divider()
            Button("No colour") { set(tag, nil) }
        } label: {
            Circle().fill(current ?? Color.primary.opacity(0.12)).frame(width: si(14), height: si(14))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Choose this tag's colour")
    }

    private func set(_ tag: String, _ value: String?) {
        TagColors.set(tag, to: value)
        colours = TagColors.read()
    }

    private func commit(_ tag: String) {
        guard let new = drafts[tag] else { return }
        drafts[tag] = nil
        TagRename.run(tag, to: new, notes: notes, saved: saved)
        colours = TagColors.read()
    }
}
