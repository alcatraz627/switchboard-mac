// SavedView.swift
// The Saved tab: links, files and folders kept in `.saved/`. A box on top adds one, the list below opens,
// tags, copies and removes them. Tag and remove show when the pointer is on a row.

import SwiftUI

/// The add box above the list: paste a link or type a file path, press Return.
struct SavedTop: View {
    @ObservedObject var saved: SavedStore = .shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.sbIcon(10)).foregroundStyle(.secondary)
                TextField("Save a link or a file path", text: $text).textFieldStyle(.plain).font(PT.label)
                    .focused($focused).onSubmit(add)
                Button { if let s = NSPasteboard.general.string(forType: .string) { text = s.trimmingCharacters(in: .whitespacesAndNewlines); add() } } label: {
                    Image(systemName: "doc.on.clipboard").font(.sbIcon(11))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Save what is on the clipboard")
            }
            .inputBox(focused: focused)
            if let n = saved.notice ?? saved.error {
                Text(n).font(PT.caption).foregroundStyle(saved.error == nil ? Color.secondary : Color.orange).padding(.leading, 4)
            }
        }
        .padding(.horizontal, PT.gap).padding(.top, PT.gap - 2).padding(.bottom, 2)
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let n = saved.add(url: SavedInput.link(from: t)) { text = ""; saved.say(n.title.isEmpty ? "Saved" : "Saved \u{201C}\(n.title)\u{201D}") }
    }
}

enum SavedInput {
    /// A pasted line as a link: a web address stays, a path (`/…` or `~/…`) becomes a `file://` link, a folder with a closing `/`.
    static func link(from raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") || t.hasPrefix("~") else { return t }
        let path = (t as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        var url = URL(fileURLWithPath: path).absoluteString   // percent-encodes, keeps file:///
        if exists, isDir.boolValue, !url.hasSuffix("/") { url += "/" }
        return url.removingPercentEncoding ?? url
    }
}

struct SavedTabView: View {
    @ObservedObject var saved: SavedStore
    @State private var query = ""
    @State private var tagFilter: Set<String> = []

    private var shown: [Note] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return saved.items.filter { n in
            (tagFilter.isEmpty || tagFilter.isSubset(of: Set(n.tags))) &&
            words.allSatisfy { w in ([n.title, n.url ?? "", n.body] + n.tags).contains { $0.lowercased().contains(w) } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            if let e = saved.error { ReadingStatus(state: .failed(e)).padding(.horizontal, 4) }
            if !saved.loaded {
                ReadingStatus(state: .loading).padding(.horizontal, 4)
            } else if saved.items.isEmpty {
                Text("Nothing saved yet. Paste a link or a file path above, or save one from your phone.").font(PT.caption)
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.sbIcon(10)).foregroundStyle(.secondary)
                    TextField("Search saved", text: $query).textFieldStyle(.plain).font(PT.caption)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.sbIcon(10)) }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    }
                }
                .inputBox(focused: false)
                tagRow
                if shown.isEmpty {
                    Text("No saves match.").font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                } else {
                    Card {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            SavedRow(item: n, saved: saved)
                        }
                    }
                }
            }
        }
        .padding(PT.gap)
    }

    private var tagRow: some View {
        let counts = saved.items.tagCounts
        return Group {
            if !counts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Image(systemName: "tag").font(.sbIcon(9.5)).foregroundStyle(.tertiary)
                        ForEach(counts, id: \.tag) { t in
                            let on = tagFilter.contains(t.tag)
                            Button { if on { tagFilter.remove(t.tag) } else { tagFilter.insert(t.tag) } } label: {
                                HStack(spacing: 4) {
                                    if let c = TagColors.read()[t.tag].flatMap(TagColors.color) { Circle().fill(c).frame(width: 7, height: 7) }
                                    Text("#\(t.tag) \(t.count)").font(.sb(10.5, weight: on ? .semibold : .regular)).lineLimit(1)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
                                .foregroundStyle(on ? Color.primary : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

private struct SavedRow: View {
    let item: Note
    @ObservedObject var saved: SavedStore
    @State private var hovering = false
    @State private var editingTags = false
    @State private var tagsText = ""
    @State private var confirmRemove = false

    private var icon: String {
        guard let u = item.url else { return "text.alignleft" }
        if u.lowercased().hasPrefix("file://") { return u.hasSuffix("/") ? "folder" : "doc" }
        return "link"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.sbIcon(11)).foregroundStyle(.secondary).frame(width: si(16)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Button { saved.open(item) } label: {
                    Text(item.heading).font(PT.label).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(item.url.map { "Open \($0)" } ?? item.heading)
                if let u = item.url, subtitle(u) != item.heading {
                    Text(subtitle(u)).font(PT.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(u)
                }
                if !item.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.tags, id: \.self) { t in
                            HStack(spacing: 3) {
                                if let c = TagColors.read()[t].flatMap(TagColors.color) { Circle().fill(c).frame(width: 6, height: 6) }
                                Text("#" + t).font(.sb(10)).lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.07)))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            // the row's own buttons: shown on hover, and always there for a screen reader and the keyboard
            HStack(spacing: 8) {
                button("tag", "Tag it") { tagsText = item.tags.joined(separator: ", "); editingTags = true }
                    .popover(isPresented: $editingTags, arrowEdge: .bottom) { tagEditor }
                button("arrow.up.right.square", "Open") { saved.open(item) }
                button("doc.on.doc", "Copy the link") { saved.copyLink(item) }
                button("trash", "Remove from Saved") { saved.remove(key: item.id) }
            }
            .opacity(hovering || editingTags ? 1 : 0)
        }
        .padding(.horizontal, PT.rowH - 4).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { saved.open(item) }
            Button("Copy the link") { saved.copyLink(item) }
            Button("Tag…") { tagsText = item.tags.joined(separator: ", "); editingTags = true }
            Divider()
            Button("Remove from Saved") { saved.remove(key: item.id) }
        }
    }

    /// Where the save points, as a person reads it: a Mac path with `~`, or the site and path.
    private func subtitle(_ u: String) -> String {
        if let url = URL(string: u), url.isFileURL { return abbreviateHome(url.path) }
        return SavedStore.guessTitle(u)
    }

    private func button(_ name: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: name).font(.sbIcon(11)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags, separated by commas").font(PT.caption).foregroundStyle(.secondary)
            TextField("read-later, work", text: $tagsText).textFieldStyle(.plain).font(PT.label).inputBox(focused: true)
                .onSubmit { commitTags() }.frame(width: 220)
            HStack { Spacer(); Button("Save") { commitTags() }.keyboardShortcut(.defaultAction) }
        }
        .padding(10)
    }

    private func commitTags() {
        saved.setTags(item.id, NoteSpec.tagList(tagsText))
        editingTags = false
    }
}
