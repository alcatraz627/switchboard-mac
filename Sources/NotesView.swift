// NotesView.swift
// The Notes tab: a one-line compose bar pinned on top, then the notes in the
// owner's order (drag the grip), then expired ones folded away at the end.

import AppKit
import SwiftUI

/// The bar above the list: one field, and icon buttons to open it up, save
/// what is on the clipboard, or save and copy the new note's path.
struct NoteCompose: View {
    @ObservedObject var notes: NotesStore
    @State private var text = ""
    @State private var expanded = false
    @State private var flash: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: expanded ? .top : .center, spacing: 6) {
                Group {
                    if expanded {
                        TextEditor(text: $text).font(PT.label).frame(height: 90).scrollContentBackground(.hidden)
                    } else {
                        // Enter saves; a note already saved is not saved twice.
                        TextField("A note. Enter saves it.", text: $text).textFieldStyle(.plain).font(PT.label)
                            .onSubmit { save(copyPath: false) }
                    }
                }
                .focused($focused)
                icon(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                     expanded ? "Back to one line" : "More room: a title line, then the body") { expanded.toggle() }
                icon("doc.on.clipboard", "Save what is on the clipboard as a note") {
                    guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { show("The clipboard has no text"); return }
                    if notes.add(s) != nil { show("Saved from the clipboard") }
                }
                icon("tray.and.arrow.down", "Save and copy the note's path") { save(copyPath: true) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear))
            .onTapGesture { NSApp.activate(ignoringOtherApps: true); focused = true }
            if let f = flash {
                Text(f).font(PT.caption).foregroundStyle(.secondary).padding(.leading, 4).transition(.opacity)
            }
        }
        .padding(.horizontal, PT.gap).padding(.top, PT.gap - 2).padding(.bottom, 2)
    }

    private func save(copyPath: Bool) {
        let before = notes.notes.count
        guard let n = notes.add(text) else { if text.isEmpty { show("Type something first") }; return }
        text = ""
        if copyPath {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(n.path, forType: .string)
        }
        show(notes.notes.count == before ? "Already saved" : copyPath ? "Saved; path copied" : "Saved")
    }

    private func show(_ s: String) {
        withAnimation { flash = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { if flash == s { flash = nil } } }
    }

    private func icon(_ name: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: name).font(.system(size: 11)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }
}

struct NotesTabView: View {
    @ObservedObject var notes: NotesStore
    @State private var showExpired = false

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            if let e = notes.error {
                ReadingStatus(state: .failed(e)).padding(.horizontal, 4)
            }
            if notes.live.isEmpty && notes.expired.isEmpty {
                Text("No notes yet. Type one above and press Enter.").font(PT.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if !notes.live.isEmpty {
                Card {
                    ReorderStack(items: notes.live, move: { notes.move($0, to: $1) }, commit: { notes.saveOrder() }) { i, n, grip in
                        VStack(spacing: 0) {
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            NoteRow(note: n, notes: notes, grip: grip)
                        }
                    }
                }
            }
            if !notes.expired.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showExpired.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(showExpired ? 90 : 0))
                            Text("EXPIRED \(notes.expired.count)").font(PT.section).tracking(0.7)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.leading, 4)
                    if showExpired {
                        Card {
                            ForEach(Array(notes.expired.enumerated()), id: \.element.id) { i, n in
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                NoteRow(note: n, notes: notes, grip: AnyView(Color.clear.frame(width: 14)))
                            }
                        }
                        .opacity(0.6)
                    }
                }
            }
        }
        .padding(PT.gap)
    }
}

/// One note: title, first line of the body, tags and what is set on it, with
/// copy buttons; clicking opens an editor below.
struct NoteRow: View {
    let note: Note
    @ObservedObject var notes: NotesStore
    let grip: AnyView
    @State private var open = false
    @State private var draft: Note?
    @State private var tagsText = ""
    @State private var expireWithReminder = false
    @State private var copied: String?
    /// Snapshots open the first note's editor so its look can be checked.
    static var startOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                grip
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).font(PT.label).fixedSize(horizontal: false, vertical: true)
                        .strikethrough(note.expired)
                    if !summary.isEmpty {
                        Text(summary).font(PT.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleOpen() }
                Spacer(minLength: 4)
                copyButton("link", "Copy the file's full path", note.path)
                copyButton("doc.on.doc", "Copy the whole note", note.content)
                copyButton("textformat", "Copy the title", note.title)
                Button { toggleOpen() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV)
            if open, draft != nil { editor.transition(.opacity) }
        }
    }

    init(note: Note, notes: NotesStore, grip: AnyView) {
        self.note = note
        self.notes = notes
        self.grip = grip
        // Snapshots start the first note open; changing state mid-capture blanks the frame.
        if Self.startOpen, notes.live.first?.id == note.id {
            _open = State(initialValue: true)
            _draft = State(initialValue: note)
        }
    }

    /// First line of the body, the tags, and a word for any expiry or reminder.
    private var summary: String {
        let f = DateFormatter(); f.dateFormat = "d MMM, h:mm a"
        var parts: [String] = []
        if let first = note.body.components(separatedBy: "\n").first(where: { !$0.isEmpty }) { parts.append(first) }
        if !note.tags.isEmpty { parts.append(note.tags.map { "#" + $0 }.joined(separator: " ")) }
        if let r = note.remindAt {
            parts.append("reminds " + f.string(from: r) + (note.remindRepeat == .never ? "" : ", " + note.remindRepeat.rawValue))
        }
        if let e = note.expires { parts.append((note.expired ? "expired " : "expires ") + f.string(from: e)) }
        return parts.joined(separator: " · ")
    }

    private func toggleOpen() {
        withAnimation(.easeOut(duration: 0.15)) {
            open.toggle()
            if open {
                draft = note
                tagsText = note.tags.joined(separator: ", ")
                expireWithReminder = note.remindAt != nil && note.expires == note.remindAt
            }
        }
    }

    private var editor: some View {
        let d = Binding(get: { draft ?? note }, set: { draft = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: d.title).textFieldStyle(.roundedBorder).font(PT.label)
            TextEditor(text: d.body).font(PT.label).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
            TextField("Tags, separated by commas", text: $tagsText).textFieldStyle(.roundedBorder).font(PT.caption)
            // Expiry: a date after which the note dims and moves to Expired.
            HStack(spacing: 6) {
                Toggle("Expires", isOn: Binding(get: { d.wrappedValue.expires != nil },
                                                set: { d.wrappedValue.expires = $0 ? Date().addingTimeInterval(86400 * 7) : nil }))
                    .toggleStyle(.checkbox).font(PT.caption)
                if d.wrappedValue.expires != nil {
                    DatePicker("", selection: Binding(get: { d.wrappedValue.expires ?? Date() }, set: { d.wrappedValue.expires = $0 }))
                        .labelsHidden().controlSize(.small).disabled(expireWithReminder)
                }
                Spacer()
            }
            // Reminder: once or on a repeat, in macOS Reminders, separate from expiry.
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { d.wrappedValue.remindAt == nil ? "off" : d.wrappedValue.remindRepeat.rawValue },
                                              set: { v in
                                                  if v == "off" { d.wrappedValue.remindAt = nil; return }
                                                  if d.wrappedValue.remindAt == nil { d.wrappedValue.remindAt = Date().addingTimeInterval(3600) }
                                                  d.wrappedValue.remindRepeat = Note.Repeat(rawValue: v) ?? .never
                                              })) {
                    Text("No reminder").tag("off")
                    Text("Remind once").tag("never")
                    Text("Every day").tag("daily")
                    Text("Every week").tag("weekly")
                    Text("Every month").tag("monthly")
                }
                .labelsHidden().controlSize(.small).fixedSize()
                if d.wrappedValue.remindAt != nil {
                    DatePicker("", selection: Binding(get: { d.wrappedValue.remindAt ?? Date() }, set: { d.wrappedValue.remindAt = $0 }))
                        .labelsHidden().controlSize(.small)
                }
                Spacer()
            }
            if d.wrappedValue.remindAt != nil, d.wrappedValue.remindRepeat == .never {
                Toggle("Expire the note when it fires", isOn: $expireWithReminder).toggleStyle(.checkbox).font(PT.caption)
            }
            HStack(spacing: 10) {
                Button { save() } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless).help("Save the changes")
                Button { open = false; draft = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Discard the changes")
                Spacer()
                Button {
                    let a = NSAlert(); a.messageText = "Delete \u{201C}\(note.title)\u{201D}?"
                    a.informativeText = "The file and any reminder it set are removed."
                    a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if a.runModal() == .alertFirstButtonReturn { notes.delete(note) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete the note")
            }
        }
        .padding(.horizontal, PT.rowH).padding(.bottom, 10).padding(.top, 2)
    }

    private func save() {
        guard var n = draft else { return }
        n.title = n.title.trimmingCharacters(in: .whitespaces).isEmpty ? note.title : n.title
        n.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if n.remindAt == nil || n.remindRepeat != .never { expireWithReminder = false }
        if expireWithReminder { n.expires = n.remindAt }
        notes.update(n)
        withAnimation(.easeOut(duration: 0.15)) { open = false; draft = nil }
    }

    private func copyButton(_ icon: String, _ help: String, _ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = icon
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == icon { copied = nil } }
        } label: {
            Image(systemName: copied == icon ? "checkmark" : icon).font(.system(size: 11))
                .foregroundStyle(copied == icon ? Color(nsColor: menuGreen) : .secondary)
                .frame(width: 16)
        }
        .buttonStyle(.borderless).help(help)
    }
}
