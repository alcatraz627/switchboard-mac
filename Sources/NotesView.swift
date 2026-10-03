// NotesView.swift
// The Notes tab: a one-line compose bar pinned on top, then the notes in the
// owner's order (drag the grip), then expired ones folded away at the end.

import AppKit
import SwiftUI

/// The bar above the list: a title line that opens into a title and body
/// sheet, with buttons to save, save what is on the clipboard, or save and
/// copy the new note's path. Enter in the title opens the body; ⌘↩ saves and
/// carries on typing in the saved note; Escape leaves the draft where it is.
struct NoteCompose: View {
    @ObservedObject var notes: NotesStore
    @ObservedObject private var nav: NotesNav
    @State private var expanded = false
    @State private var flash: String?
    @State private var focus: NoteSheet.Field?
    /// Snapshots draw the composer opened up.
    static var startExpanded = false

    init(notes: NotesStore, space: String = ScrollTargets.space) {
        self.notes = notes
        nav = NotesNav.forSpace(space)
        if Self.startExpanded { _expanded = State(initialValue: true) }
    }

    private var title: String { nav.draftTitle }
    private var text: String { nav.draftBody }

    var body: some View {
        content
            .onChange(of: focus) { f in
                if let f {
                    nav.composeField = f == .body ? .body : .title
                    if nav.focus != .compose { nav.focus = .compose }
                } else if nav.focus == .compose {
                    nav.focus = .none
                }
            }
            .onChange(of: nav.focus) { f in
                if f == .compose, focus == nil { focus = expanded && nav.composeField == .body ? .body : .title }
                else if f != .compose, focus != nil { focus = nil }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Group {
                    if expanded {
                        VStack(alignment: .leading, spacing: 0) {
                            NoteSheet(title: $nav.draftTitle, text: $nav.draftBody, focus: $focus, titlePrompt: "Title", bodyPrompt: "Note", bodyMax: 160)
                            ColorBalls(selection: $nav.draftColor, allowNone: true, size: 11).padding(.horizontal, 5).padding(.bottom, 4)
                        }
                    } else {
                        ZStack(alignment: .leading) {
                            if title.isEmpty { Text("New note").font(PT.label).foregroundStyle(.tertiary).allowsHitTesting(false) }
                            EditorText(text: $nav.draftTitle, focused: Binding(get: { focus == .title }, set: { focus = $0 ? .title : nil }),
                                       font: .systemFont(ofSize: 12 * UIScale.text), singleLine: true, onReturn: { before, after in
                                           let r = InputRules.splitTitle(before: before, after: after, body: text)
                                           nav.draftTitle = r.title; nav.draftBody = r.body
                                           withAnimation(Motion.slow) { expanded = true }
                                           focus = .body
                                       })
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focus != nil ? Color.accentColor.opacity(0.6) : .clear))
                // expanded, the buttons stack down the side so the sheet keeps its width
                let buttons = Group {
                    icon(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         expanded ? "Back to one line" : "Open a title and body") {
                        withAnimation(Motion.slow) { expanded.toggle() }
                    }
                    icon("checkmark", "Save (⌘↩); ⇧⌘↩ saves and pins it") { save(copyPath: false) }
                        .keyboardShortcut(.return, modifiers: .command)
                    icon("pin", "Save and pin it to the hover card (⇧⌘↩)") { save(copyPath: false, pin: true) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                    icon("doc.on.clipboard", "Save what is on the clipboard as a note") {
                        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { show("The clipboard has no text"); return }
                        let before = notes.notes.count
                        if notes.add(s) != nil { show(notes.notes.count == before ? "Already saved" : "Saved from the clipboard") }
                    }
                    icon("tray.and.arrow.down", "Save and copy the note's path") { save(copyPath: true) }
                }
                if expanded { VStack(spacing: 8) { buttons }.padding(.top, 6) } else { HStack(spacing: 6) { buttons }.padding(.top, 6) }
            }
            if let f = flash {
                Text(f).font(PT.caption).foregroundStyle(.secondary).padding(.leading, 4).transition(Motion.arrive)
            }
        }
        .padding(.horizontal, PT.gap).padding(.top, PT.gap - 2).padding(.bottom, 2)
        .onAppear {
            // the new note gets the keyboard, unless a note below is open or has the keyboard
            guard InputRules.focusNewInput(editing: EditingState.shared.note), nav.focus == .none || nav.focus == .compose else { return }
            DispatchQueue.main.async { if focus == nil { focus = .title } }
        }
    }

    private func save(copyPath: Bool, pin: Bool = false) {
        let before = notes.notes.count
        guard var n = notes.add(title: title, body: text, color: nav.draftColor) else {
            if !InputRules.canSave(title: title, body: text) { show("Type a title or a note first") }
            return
        }
        nav.draftTitle = ""; nav.draftBody = ""; nav.draftColor = nil
        if pin { n.pinned = true; notes.update(n) }
        if copyPath {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(n.path, forType: .string)
        }
        show(notes.notes.count == before ? "Already saved" : copyPath ? "Saved; path copied" : pin ? "Saved and pinned" : "Saved")
    }

    private func show(_ s: String) {
        withAnimation { flash = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { if flash == s { flash = nil } } }
    }

    private func icon(_ name: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: name).font(.sbIcon(11)) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }
}

struct NotesTabView: View {
    @ObservedObject var notes: NotesStore
    @Environment(\.panelSpace) private var space

    var body: some View { NotesList(notes: notes, nav: NotesNav.forSpace(space)) }
}

/// The notes under the colour filter, each row knowing whether it has the keyboard.
private struct NotesList: View {
    @ObservedObject var notes: NotesStore
    @ObservedObject var nav: NotesNav
    @State private var showExpired = false

    var body: some View {
        let shown = nav.visible(notes.live)
        VStack(alignment: .leading, spacing: PT.gap) {
            if let e = notes.error {
                ReadingStatus(state: .failed(e)).padding(.horizontal, 4)
            }
            if !notes.loaded {
                ReadingStatus(state: .loading).padding(.horizontal, 4)
            } else if notes.live.isEmpty && notes.expired.isEmpty && notes.error == nil {
                Text("No notes yet. Type one above and press Enter.").font(PT.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if !notes.live.isEmpty {
                NoteFilterBar(nav: nav, hidden: notes.live.count - shown.count)
            }
            if !shown.isEmpty {
                Card {
                    ReorderStack(items: shown, move: { notes.move($0, to: $1) }, commit: { notes.saveOrder() }) { i, n, grip in
                        VStack(spacing: 0) {
                            if i > 0 { Divider().padding(.leading, PT.rowH) }
                            NoteRow(note: n, notes: notes, nav: nav, grip: grip)
                                .revealFlash("note-" + n.id).id("note-" + n.id)
                        }
                    }
                }
            } else if !notes.live.isEmpty {
                Text("No notes in the chosen colours.").font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            NotesFolderLink()
            if !notes.expired.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Button { withAnimation(Motion.slow) { showExpired.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.sbIcon(8, weight: .semibold))
                                .rotationEffect(.degrees(showExpired ? 90 : 0))
                            Text("Expired \(notes.expired.count)").font(PT.section)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.leading, 4)
                    if showExpired {
                        Card {
                            ForEach(Array(notes.expired.enumerated()), id: \.element.id) { i, n in
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                NoteRow(note: n, notes: notes, nav: nav, grip: AnyView(Color.clear.frame(width: si(14))))
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

/// One small row: "All" and the eight colours. Chosen colours narrow the list;
/// ← and → walk it from the keyboard, Space picks.
struct NoteFilterBar: View {
    @ObservedObject var nav: NotesNav
    let hidden: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("All").font(.sb(10.5, weight: nav.filter.isEmpty ? .semibold : .regular))
                .foregroundStyle(nav.filter.isEmpty ? Color.primary : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(nav.filter.isEmpty ? 0.1 : 0)))
                .keyRing(nav.focus == .filter(0), radius: 8)
                .contentShape(Rectangle())
                .onTapGesture { nav.toggleFilter(0) }
            ForEach(Array(timerColors.enumerated()), id: \.element.0) { i, c in
                let on = nav.filter.contains(c.0)
                Circle().fill(c.1).frame(width: si(10), height: si(10))
                    .opacity(nav.filter.isEmpty || on ? 1 : 0.35)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.8 : 0), lineWidth: 1.5).padding(-3))
                    .padding(3)
                    .keyRing(nav.focus == .filter(i + 1), radius: 9)
                    .contentShape(Circle())
                    .onTapGesture { nav.toggleFilter(i + 1) }
                    .accessibilityLabel(c.0)
            }
            Spacer(minLength: 4)
            if hidden > 0 { Text("\(hidden) hidden").font(PT.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 4)
    }
}

/// The folder the notes live in: click opens it in Finder, the icon copies it.
struct NotesFolderLink: View {
    @State private var copied = false

    var body: some View {
        let dir = NotesStore.dir
        HStack(spacing: 6) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.sbIcon(10.5))
                    Text(abbreviateHome(dir)).font(PT.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.link).help("Open the notes folder in Finder")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dir, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.sbIcon(10.5))
                    .foregroundStyle(copied ? Color(nsColor: menuGreen) : .secondary)
            }
            .buttonStyle(.borderless).help("Copy the folder's path")
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

/// One note: title, first line of the body, tags and what is set on it, with
/// copy buttons; clicking opens an editor below.
struct NoteRow: View {
    let note: Note
    @ObservedObject var notes: NotesStore
    @ObservedObject var nav: NotesNav
    let grip: AnyView
    /// Snapshots draw the first note open without touching where the keyboard is.
    @State private var snapshotOpen = false
    @State private var draft: Note?
    @State private var tagsText = ""
    @State private var expireWithReminder = false
    @State private var copied: String?
    @State private var savedAt: Date?
    /// The last save was refused because the note was empty.
    @State private var refused = false
    @State private var focus: NoteSheet.Field?
    /// Snapshots open the first note's editor so its look can be checked.
    static var startOpen = false

    @State private var hovering = false

    /// This note's place in the keyboard's path: open (and which block, reading or typing) or not.
    private var openState: (block: NoteBlock?, typing: Bool)? {
        if case .open(let id, let b, let t) = nav.focus, id == note.id { return (b, t) }
        return snapshotOpen ? (nil, true) : nil
    }
    private var open: Bool { openState != nil }

    var body: some View {
        rows
            .onChange(of: open) { o in
                if o { begin() } else { save() }
                if o { EditingState.shared.note = note.id } else if EditingState.shared.note == note.id { EditingState.shared.note = nil }
            }
            .onChange(of: nav.focus) { _ in
                let want: NoteSheet.Field? = openState?.block.map { $0 == .title ? .title : .body }
                if focus != want { focus = want }
            }
            .onChange(of: focus) { f in
                // a click into a field of this note: the keyboard is here, typing
                guard let f, let s = openState else { return }
                let b: NoteBlock = f == .title ? .title : .body
                if s.block != b { nav.focus = .open(note.id, b, typing: s.typing) }
            }
            .onChange(of: nav.saveTick) { _ in if open { save() } }
            .onAppear {
                // the note ⌘↩ just saved is drawn already open, so nothing above fires for it
                guard open, draft == nil else { return }
                begin()
                EditingState.shared.note = note.id
                focus = openState?.block.map { $0 == .title ? .title : .body }
            }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                grip
                if let c = note.color { Circle().fill(timerColor(c)).frame(width: si(8), height: si(8)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.heading).font(PT.label).fixedSize(horizontal: false, vertical: true)
                        .strikethrough(note.expired)
                    if let url = firstLink {
                        // a note that starts with a link shows it as one, opening on click
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: url.isFileURL ? "doc" : "link").font(.sbIcon(9.5))
                                Text(linkLabel(url)).font(PT.caption).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.link).help("Open \(url.absoluteString)")
                    }
                    if !summary.isEmpty {
                        Text(summary).font(PT.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                // copy actions stay out of the way until the row is pointed at
                let has = InputRules.copyButtons(title: note.title, body: note.body)
                HStack(spacing: 2) {
                    copyButton("link", "Copy the file's full path", note.path)
                    if has.body { copyButton("doc.on.doc", "Copy the note's text", note.body) }
                    if has.title { copyButton("textformat", "Copy the title", note.title) }
                }
                .opacity(hovering || open ? 1 : 0)
                // a pinned note shows on the menu-bar quick page
                Button { setPinned(!note.pinned) } label: {
                    Image(systemName: note.pinned ? "pin.fill" : "pin").font(.sbIcon(11))
                        .foregroundStyle(note.pinned ? Color.accentColor : .secondary).frame(width: si(16))
                }
                .buttonStyle(.borderless).help(note.pinned ? "Unpin: leave the menu-bar quick page" : "Pin to the menu-bar quick page")
                .opacity(note.pinned || hovering || open ? 1 : 0)
                Image(systemName: "chevron.right").font(.sbIcon(9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
            }
            .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering && !open ? 0.05 : 0)))
            .keyRing(nav.focus == .row(note.id))
            .contentShape(Rectangle())
            .onTapGesture { toggleOpen() }
            .onHover { hovering = $0 }
            .contextMenu {
                Button(note.pinned ? "Unpin" : "Pin to the quick page") { setPinned(!note.pinned) }
                Divider()
                if !note.title.isEmpty { Button("Copy title") { copy(note.title) } }
                if !note.body.isEmpty { Button("Copy text") { copy(note.body) } }
                Button("Copy title and text") { copy(note.content) }
                Button("Copy file path") { copy(note.path) }
            }
            if open, draft != nil { editor.transition(Motion.arrive) }
        }
    }

    /// The first body line, when it is a link (http or a file URL).
    private var firstLink: URL? {
        guard let first = note.body.components(separatedBy: "\n").first(where: { !$0.isEmpty })?
                .trimmingCharacters(in: .whitespaces),
              first.hasPrefix("http") || first.hasPrefix("file://"),
              let u = URL(string: first) else { return nil }
        return u
    }
    /// A link as a person reads it: the file name, or the site and path.
    private func linkLabel(_ u: URL) -> String {
        if u.isFileURL { return u.lastPathComponent }
        return (u.host ?? "") + u.path
    }
    private func setPinned(_ on: Bool) {
        var n = draft ?? note
        n.pinned = on
        if draft != nil { draft = n }
        notes.update(n)
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    init(note: Note, notes: NotesStore, nav: NotesNav, grip: AnyView) {
        self.note = note
        self.notes = notes
        self.nav = nav
        self.grip = grip
        // Snapshots start the first note open; changing state mid-capture blanks the frame.
        if Self.startOpen, notes.live.first?.id == note.id {
            _snapshotOpen = State(initialValue: true)
            _draft = State(initialValue: note)
        }
    }

    /// First line of the body, the tags, and a word for any expiry or reminder.
    private static let shortDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM, h:mm a"; return f }()
    private static let longDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"; return f }()

    private var summary: String {
        let f = Self.shortDate
        var parts: [String] = []
        // with no title the body's first line is already the heading; show the next one
        let bodyLines = note.body.components(separatedBy: "\n").filter { !$0.isEmpty }
        if firstLink == nil, let first = bodyLines.dropFirst(note.title.isEmpty ? 1 : 0).first { parts.append(first) }
        if !note.tags.isEmpty { parts.append(note.tags.map { "#" + $0 }.joined(separator: " ")) }
        if let r = note.remindAt {
            parts.append("reminds " + f.string(from: r) + (note.remindRepeat == .never ? "" : ", " + note.remindRepeat.rawValue))
        }
        if let e = note.expires { parts.append((note.expired ? "expired " : "expires ") + f.string(from: e)) }
        return parts.joined(separator: " · ")
    }

    /// A click on the row: open it ready to edit, or close it (closing keeps whatever was typed).
    private func toggleOpen() {
        snapshotOpen = false
        withAnimation(Motion.slow) {
            nav.focus = open ? .row(note.id) : .open(note.id, nil, typing: true)
        }
    }

    private func begin() {
        draft = note
        tagsText = note.tags.joined(separator: ", ")
        expireWithReminder = note.remindAt != nil && note.expires == note.remindAt
        // the cursor position carried from the new note applies once
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { nav.caret = nil }
    }

    /// The editor saves by itself shortly after each change, so there is no
    /// Save button to find; collapsing the row saves too.
    private var editor: some View {
        let d = Binding(get: { draft ?? note }, set: { draft = $0 })
        let f = Self.longDate
        return VStack(alignment: .leading, spacing: 8) {
            // title and body are one sheet, like a note app, not two boxed fields
            VStack(alignment: .leading, spacing: 0) {
                NoteSheet(title: d.title, text: d.body, focus: $focus, editable: openState?.typing ?? true, caret: nav.caret,
                          onClickReadOnly: { f in nav.focus = .open(note.id, f == .title ? .title : .body, typing: true) })
                HStack(spacing: 3) {
                    Text("#").font(PT.caption).foregroundStyle(.tertiary)
                    TextField("tags, separated by commas", text: Binding(get: { tagsText }, set: { t in
                        tagsText = t
                        d.wrappedValue.tags = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    })).textFieldStyle(.plain).font(PT.caption)
                }
                .padding(.horizontal, 8).padding(.bottom, 7)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            // when it expires and when it reminds: one row, each an action until it is set
            HStack(spacing: 6) {
                WhenButton(title: "Expire this note at", presets: WhenPreset.long,
                           extra: d.wrappedValue.expires == nil ? [] : [("No expiry", { d.wrappedValue.expires = nil; expireWithReminder = false })],
                           initial: d.wrappedValue.expires,
                           onPick: { t, _ in d.wrappedValue.expires = t; expireWithReminder = false }) {
                    chip(icon: "hourglass", d.wrappedValue.expires.map { "Expires " + f.string(from: $0) } ?? "Add expiry",
                         set: d.wrappedValue.expires != nil)
                }
                if d.wrappedValue.expires != nil {
                    clearButton("Remove the expiry") { d.wrappedValue.expires = nil; expireWithReminder = false }
                }
                WhenButton(title: "Remind me in macOS Reminders", presets: WhenPreset.long,
                           choices: ["Once", "Every day", "Every week", "Every month"],
                           extra: d.wrappedValue.remindAt == nil ? [] : [("No reminder", { d.wrappedValue.remindAt = nil; expireWithReminder = false })],
                           initial: d.wrappedValue.remindAt,
                           initialChoice: [.never, .daily, .weekly, .monthly].firstIndex(of: d.wrappedValue.remindRepeat) ?? 0,
                           onPick: { t, i in
                               d.wrappedValue.remindAt = t
                               d.wrappedValue.remindRepeat = [.never, .daily, .weekly, .monthly][i]
                               if expireWithReminder { d.wrappedValue.expires = t }
                           }) {
                    chip(icon: "bell", d.wrappedValue.remindAt.map { "Reminds " + f.string(from: $0)
                        + (d.wrappedValue.remindRepeat == .never ? "" : ", " + d.wrappedValue.remindRepeat.rawValue) } ?? "Add reminder",
                         set: d.wrappedValue.remindAt != nil)
                }
                if d.wrappedValue.remindAt != nil {
                    clearButton("Remove the reminder") { d.wrappedValue.remindAt = nil; expireWithReminder = false }
                }
                Spacer()
            }
            if d.wrappedValue.remindAt != nil, d.wrappedValue.remindRepeat == .never {
                Toggle("Expire the note when it fires", isOn: Binding(get: { expireWithReminder }, set: { on in
                    expireWithReminder = on
                    d.wrappedValue.expires = on ? d.wrappedValue.remindAt : nil
                })).toggleStyle(.checkbox).font(PT.caption)
            }
            ColorBalls(selection: d.color, allowNone: true, size: 12)
            HStack(spacing: 10) {
                Text(refused ? "Empty notes are not saved; delete removes a note"
                     : savedAt.map { "Saved " + age($0) } ?? "Saves as you type")
                    .font(PT.caption).foregroundStyle(refused ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                Spacer()
                Button {
                    let a = NSAlert(); a.messageText = "Delete \u{201C}\(note.heading)\u{201D}?"
                    a.informativeText = "The file and any reminder it set are removed."
                    a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if a.runModal() == .alertFirstButtonReturn { notes.delete(note) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete the note")
            }
        }
        .padding(.horizontal, PT.rowH).padding(.bottom, 10).padding(.top, 2)
        // Every change lands 0.7 s after the typing stops.
        .task(id: draft) {
            guard let n = draft, n != note else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { save() }
        }
    }

    /// A set value is a filled pill; an unset one reads as an action ("+ Add reminder").
    private func chip(icon: String, _ text: String, set: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: set ? icon : "plus").font(.sbIcon(10, weight: .medium))
            Text(text).font(.sb(11))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(set ? Color.accentColor.opacity(0.14) : Color.clear))
        .overlay(Capsule().strokeBorder(set ? Color.clear : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .foregroundStyle(set ? Color.accentColor : .secondary)
    }
    private func clearButton(_ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: "xmark.circle.fill").font(.sbIcon(11)) }
            .buttonStyle(.borderless).foregroundStyle(.tertiary).help(help)
    }

    private func save() {
        guard var n = draft, n != note else { refused = false; return }
        // a note with neither title nor text is refused, not saved; Delete is how a note goes
        guard InputRules.canSave(title: n.title, body: n.body) else { refused = true; return }
        n.title = n.title.trimmingCharacters(in: .whitespaces)
        refused = false
        notes.update(n)
        savedAt = Date()
    }

    private func copyButton(_ icon: String, _ help: String, _ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = icon
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == icon { copied = nil } }
        } label: {
            Image(systemName: copied == icon ? "checkmark" : icon).font(.sbIcon(11))
                .foregroundStyle(copied == icon ? Color(nsColor: menuGreen) : .secondary)
                .frame(width: si(16))
        }
        .buttonStyle(.borderless).help(help)
    }
}
