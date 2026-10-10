// NotesHistory.swift
// A note's versions, one per save, read from the folder's git log. The list
// opens from the "n versions" chip of an open note (Return on it from the
// keyboard); ↑/↓ walk the versions, the chosen one shows underneath, ⌘↩ puts it
// back in the editor, Escape closes. Nothing is thrown away: bringing a version
// back is one more save, so the text it replaced stays in the list.

import AppKit
import SwiftUI

struct HistoryPanel: View {
    let note: Note
    let versions: [NoteVersion]
    /// The file's text at one version, by its hash.
    var read: (String) -> String?
    /// The owner wants this version's title and text back in the editor.
    var restore: (Note) -> Void
    var dismiss: () -> Void = {}

    @State private var picked: Int
    @FocusState private var focused: Bool

    private static let when: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"; return f }()

    init(note: Note, versions: [NoteVersion], read: @escaping (String) -> String?, restore: @escaping (Note) -> Void, dismiss: @escaping () -> Void = {}) {
        self.note = note
        self.versions = versions
        self.read = read
        self.restore = restore
        self.dismiss = dismiss
        // the newest version is chosen from the start, so the panel opens at its full size
        _picked = State(initialValue: 0)
    }

    /// The chosen version, parsed as the note it was.
    private var shown: Note? {
        guard versions.indices.contains(picked) else { return nil }
        return read(versions[picked].sha).flatMap { NotesStore.parse(id: note.id, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(versions.isEmpty ? "No versions yet" : versions.count == 1 ? "1 version" : "\(versions.count) versions")
                .font(.sb(12, weight: .semibold))
            if !versions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(versions.prefix(8).enumerated()), id: \.element.sha) { i, v in
                        HStack(spacing: 6) {
                            Text(age(v.when)).font(.sb(11)).foregroundStyle(.secondary)
                                .frame(width: sw(58), alignment: .leading)
                            Text(v.reason).font(.sb(11)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(v.sha).font(.sb(10).monospaced()).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(picked == i ? 0.18 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { picked = i }
                        .help(Self.when.string(from: v.when))
                    }
                    if versions.count > 8 {
                        Text("and \(versions.count - 8) older").font(PT.caption).foregroundStyle(.tertiary).padding(.top, 3)
                    }
                }
            }
            if let s = shown {
                ScrollView {
                    Text(s.content).font(.sb(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                HStack(spacing: 6) {
                    Text("↑/↓ choose").font(PT.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Use this version") { restore(s); dismiss() }
                        .sbControlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Puts this text back in the editor (⌘↩); the text it replaces stays in the list")
                }
            }
        }
        .padding(12)
        .frame(width: sw(320))
        .focusable()
        .focused($focused)
        .onKeyPress(.upArrow) { picked = max(0, picked - 1); return .handled }
        .onKeyPress(.downArrow) { picked = min(min(versions.count, 8) - 1, picked + 1); return .handled }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focused = true
        }
    }
}

/// Three made-up versions, so the picker can be drawn without a repository.
enum HistoryFixture {
    static let note = Note(id: "20261010-220000", title: "Groceries", body: "- milk\n- eggs", tags: [], created: Date())
    static let versions = [
        NoteVersion(sha: "a1b2c3d", when: Date().addingTimeInterval(-120), reason: "save"),
        NoteVersion(sha: "9f8e7d6", when: Date().addingTimeInterval(-3600), reason: "merge: both sides kept"),
        NoteVersion(sha: "0c1d2e3", when: Date().addingTimeInterval(-86400 * 2), reason: "save"),
    ]
    static func read(_ sha: String) -> String? {
        sha == "0c1d2e3" ? "---\ntitle: Groceries\n---\n- milk\n" : "---\ntitle: Groceries\n---\n- milk\n- eggs\n"
    }
}
