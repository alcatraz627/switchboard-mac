// Inputs.swift
// The text inputs every tab shares, so typing behaves the same everywhere:
// one look for a field, Enter does the field's main action, Escape only lets
// go of the keyboard (it never closes or deletes anything), and a field can be
// given the keyboard from outside. The note sheet (a title over a body) is
// built from them and is meant for any title-and-text editing later.

import AppKit
import SwiftUI

// ── The rules, without any view, so a probe can check them ──────────────────

enum InputRules {
    /// Enter in a title splits it at the cursor: what is before stays the
    /// title, and what is after goes to the top of the body on its own line.
    static func splitTitle(before: String, after: String, body: String) -> (title: String, body: String) {
        let title = before.trimmingCharacters(in: .whitespaces)
        let rest = after.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (title, body) }
        return (title, body.isEmpty ? rest : rest + "\n" + body)
    }

    /// A note needs a title or a body; one with neither is not saved (Delete removes a note).
    static func canSave(title: String, body: String, url: String = "") -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The copy buttons a note row offers: the body's copy only when there is
    /// a body, the title's only when there is a title.
    static func copyButtons(title: String, body: String) -> (body: Bool, title: Bool) {
        (!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !title.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// What the tag box adds: one tag per comma, spaces inside a tag kept as one, no repeats, nothing empty. A "pin"
    /// tag would turn the note into a pin, a tag is at most 32 characters and a note keeps at most 12, the limits the
    /// phone and the extension keep too; a refusal adds nothing and says why.
    static func addTags(typed: String, to tags: [String]) -> (tags: [String], problem: String?) {
        var seen = Set<String>()
        let words = typed.split(separator: ",").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let fresh = words.filter { !tags.contains($0) }
        if words.contains(where: { $0.lowercased() == "pin" }) { return (tags, "\u{201C}pin\u{201D} is kept for pins; pin the note instead") }
        if words.contains(where: { $0.count > 32 }) { return (tags, "A tag is at most 32 characters") }
        if tags.count + fresh.count > 12 { return (tags, "A note keeps at most 12 tags") }
        return (tags + fresh, nil)
    }

    /// A title as a single line: its lines joined by a space.
    static func cleanTitle(_ t: String) -> String {
        t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The title and body to save when a title was typed or pasted. A title is one line of at most 200 characters, the
    /// way the extension keeps it; what runs over is cut at a word and moved to the top of the body, so no word is
    /// discarded. A title that was not touched (`new == old`) is left exactly as it is, whatever its length.
    static func settleTitle(old: String, new: String, body: String) -> (title: String, body: String) {
        if new == old { return (new, body) }
        let one = cleanTitle(new)
        guard one.count > 200 else { return (one, body) }
        let cutAt = one.index(one.startIndex, offsetBy: 200)
        var cut = cutAt
        // inside a word: back up to the last space so the word goes whole to the body
        if one[cutAt] != " ", let sp = one[..<cutAt].lastIndex(of: " ") { cut = sp }
        let title = String(one[..<cut]).trimmingCharacters(in: .whitespaces)
        let rest = String(one[cut...]).trimmingCharacters(in: .whitespaces)
        return (title, body.isEmpty ? rest : rest + "\n\n" + body)
    }

    /// Whether opening a tab should hand its "new" input the keyboard: not
    /// while something on the tab is being edited.
    static func focusNewInput(editing: String?) -> Bool { editing == nil }
}

/// What is being edited on the Notes and Reminders tabs, so opening the tab
/// leaves an edit in progress alone instead of moving the keyboard to "new".
final class EditingState: ObservableObject {
    static let shared = EditingState()
    /// The note whose editor is open.
    @Published var note: String?
    /// The timer whose label is being renamed.
    @Published var timer: String?
}

// ── One look for every field ────────────────────────────────────────────────

/// The panel's field look: the soft fill the tab bar uses, an accent edge while typing.
struct InputBox: ViewModifier {
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear))
    }
}

extension View {
    func inputBox(focused: Bool) -> some View { modifier(InputBox(focused: focused)) }

    /// How a name (a device, a network, a file) fits a line: whole when it
    /// fits, otherwise its middle gives way so both ends stay readable. Prose
    /// wraps instead; this is only for names. The full name is the tooltip.
    func nameFit(_ full: String) -> some View {
        lineLimit(1).truncationMode(.middle).help(full)
    }

    /// Lets the text be selected and copied with ⌘C, with no change to how it looks.
    @ViewBuilder func selectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { self }
    }
}

// ── A text view that knows Enter, Escape and focus ──────────────────────────

/// An NSTextView that reports when it gains and loses the keyboard.
final class EditorTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    /// A click on text that is open only to read: the owner means to edit it.
    var onClickReadOnly: (() -> Void)?
    /// A picture pasted into the text; the owner of the view saves it and links it.
    var onImage: ((Data, EditorTextView) -> Void)?
    /// ⌘S, ⌥⌘↑ ⌥⌘↓ (the note before or after this one) and ⌘⇧⌫: acted on by whoever owns the note.
    var onSave: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onDelete: (() -> Void)?
    /// The marker Return just put on a new list line, watched so a marker typed over it is folded in.
    private var autoMarker: ListEdit.AutoMarker?

    /// Applies a formatting edit to this text view's own text and selection, as one undoable change. The edit
    /// is made on the view the key or button belongs to, so it does not depend on which app or window is in front.
    @discardableResult
    func applyFormat(_ k: NoteFormat.Kind) -> Bool {
        guard isEditable, !isFieldEditor, let e = NoteFormat.edit(k, string, selectedRange(), clipboard: NSPasteboard.general.string(forType: .string)) else { return false }
        let all = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: all, replacementString: e.text) else { return true }
        replaceCharacters(in: all, with: e.text)
        didChangeText()
        setSelectedRange(e.selection)
        return true
    }

    /// The keys of the body editor, whether they arrive as a key equivalent or as a plain key down.
    private func editKey(_ e: NSEvent) -> Bool {
        guard isEditable, !isFieldEditor else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch mods {
        case .command:
            switch ch {
            case "b": return applyFormat(.bold)
            case "i": return applyFormat(.italic)
            case "e": return applyFormat(.code)
            case "k": return applyFormat(.link)
            case "s": if let onSave { onSave(); return true }
            default: break
            }
        case [.command, .shift]:
            switch Int(e.keyCode) {
            case 7: return applyFormat(.strike)      // X
            case 4: return applyFormat(.heading)     // H
            case 47: return applyFormat(.quote)      // .
            case 26: return applyFormat(.olist)      // 7
            case 51: if let onDelete { onDelete(); return true }
            default: break
            }
        case [.command, .option]:
            if e.keyCode == 126 || e.keyCode == 125, let onStep { onStep(e.keyCode == 126 ? -1 : 1); return true }
        default: break
        }
        return false
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        editKey(e) || super.performKeyEquivalent(with: e)
    }
    /// Tab indents the lines the selection touches (Shift-Tab takes it back); Return carries a list on.
    private func typingKey(_ e: NSEvent) -> Bool {
        guard isEditable, !isFieldEditor, !hasMarkedText() else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if e.keyCode == 48, mods.isDisjoint(with: [.command, .option, .control]) {
            LineEdit.apply(ListEdit.indent(string, selectedRange(), outdent: mods.contains(.shift)), to: self)
            return true
        }
        if e.keyCode == 36 || e.keyCode == 76, mods.isDisjoint(with: [.command, .shift, .control]),
           let edit = ListEdit.continueList(string, selectedRange()) {
            LineEdit.apply(edit, to: self)
            autoMarker = ListEdit.autoMarker(string, caret: edit.selection.location)
            return true
        }
        return false
    }
    override func didChangeText() {
        super.didChangeText()
        guard let a = autoMarker else { return }
        let sel = selectedRange()
        if sel.length == 0, let fix = ListEdit.absorbTyped(string, caret: sel.location, auto: a) {
            autoMarker = nil
            LineEdit.apply(fix, to: self)
            return
        }
        let ns = string as NSString, end = a.lineStart + (a.prefix as NSString).length
        guard ns.length >= end, sel.location >= end, ns.substring(with: NSRange(location: a.lineStart, length: end - a.lineStart)) == a.prefix else { autoMarker = nil; return }
        if ns.substring(with: NSRange(location: end, length: sel.location - end)).range(of: "^[-*+0-9.)\\[\\] xX]*$", options: .regularExpression) == nil { autoMarker = nil }
    }
    /// ⌥↑ ⌥↓ move the lines the selection touches; ⌥⇧↑ ⌥⇧↓ copy them above or below, as in VS Code.
    private func lineKey(_ e: NSEvent) -> Bool {
        guard isEditable, e.keyCode == 126 || e.keyCode == 125 else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .option || mods == [.option, .shift] else { return false }
        let up = e.keyCode == 126
        guard let edit = mods == .option ? LineEdit.move(string, selectedRange(), up: up) : LineEdit.duplicate(string, selectedRange(), up: up) else { return true }
        LineEdit.apply(edit, to: self)
        return true
    }
    override func keyDown(with e: NSEvent) {
        if editKey(e) || lineKey(e) || typingKey(e) { return }
        super.keyDown(with: e)
    }
    // A picture file dropped on the text is attached, like a pasted one; other drops insert as before.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onImage, isEditable, let d = Self.pastedImageFile(sender.draggingPasteboard) { onImage(d, self); return true }
        return super.performDragOperation(sender)
    }
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // A copied picture file (a screenshot's thumbnail, a Finder copy) also carries its path as
        // text; it is the picture that is meant, so it goes in as one, not as the path.
        if let onImage, let d = Self.pastedImageFile(pb) { onImage(d, self); return }
        if let onImage, pb.string(forType: .string) == nil, let d = pb.data(forType: .png) ?? pb.data(forType: .tiff) { onImage(d, self); return }
        super.paste(sender)
    }
    /// The first picture file on the clipboard, read as data; nil when it holds no picture file.
    static func pastedImageFile(_ pb: NSPasteboard) -> Data? {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let pictures: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "bmp"]
        guard let url = urls.first(where: { pictures.contains($0.pathExtension.lowercased()) }) else { return nil }
        return try? Data(contentsOf: url)
    }
    override func mouseDown(with e: NSEvent) {
        if !isEditable { onClickReadOnly?() }
        super.mouseDown(with: e)
    }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
}

/// Plain text, one line or many, that grows with what is typed and never
/// shows a scroll bar. Return in a one-line field hands back the text before
/// and after the cursor; Escape lets go of the keyboard.
struct EditorText: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var font: NSFont = .systemFont(ofSize: 12 * UIScale.text)
    var singleLine = false
    var maxHeight: CGFloat = 220
    /// Return in a one-line field: the text before the cursor, and after it.
    var onReturn: ((String, String) -> Void)? = nil
    /// When the keyboard is handed over from outside, put the cursor at the start.
    var caretAtStart = false
    /// False shows the text to read: it can hold the keyboard, be selected and copied, not changed.
    var editable = true
    /// Where the cursor goes when the keyboard is handed over from outside, if not the default.
    var caret: Int? = nil
    var onClickReadOnly: (() -> Void)? = nil
    var onSave: (() -> Void)? = nil
    var onStep: ((Int) -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onImage: ((Data, EditorTextView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = EditorTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = font
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isFieldEditor = singleLine   // Tab moves on, as in any form
        tv.string = text
        tv.isEditable = editable
        tv.delegate = context.coordinator
        tv.onFocus = { [weak coord = context.coordinator] on in coord?.focusChanged(on) }
        tv.onSave = onSave; tv.onStep = onStep; tv.onDelete = onDelete
        tv.onImage = onImage
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.borderType = .noBorder
        context.coordinator.textView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text { tv.string = text }
        if tv.font != font { tv.font = font }
        if tv.isEditable != editable {
            tv.isEditable = editable
            // starting to type puts the cursor at the end of what was being read
            if editable, tv.window?.firstResponder === tv, caret == nil {
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
        tv.onClickReadOnly = onClickReadOnly
        tv.onSave = onSave; tv.onStep = onStep; tv.onDelete = onDelete
        tv.onImage = onImage
        let has = tv.window?.firstResponder === tv
        let coord = context.coordinator
        // Each hand-over runs a moment later and checks it is still wanted then: two
        // fields acting on a stale wish pass the keyboard between them forever.
        if focused && !has {
            let at = caret
            let atStart = caretAtStart, canEdit = editable
            // The view can still be joining its window when this runs (after ⌘↩ the new note's field is rebuilt);
            // a wish that finds no window is tried again shortly, up to a second, instead of being dropped.
            func handOver(_ triesLeft: Int) {
                guard coord.parent.focused else { return }
                guard let w = tv.window else {
                    if triesLeft > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handOver(triesLeft - 1) } }
                    return
                }
                guard w.firstResponder !== tv else { return }
                w.makeFirstResponder(tv)
                let len = (tv.string as NSString).length
                if let at { tv.setSelectedRange(NSRange(location: min(at, len), length: 0)) }
                else if atStart { tv.setSelectedRange(NSRange(location: 0, length: 0)) }
                else if !canEdit { tv.setSelectedRange(NSRange(location: 0, length: 0)) }
            }
            DispatchQueue.main.async { handOver(20) }
        } else if !focused && has {
            DispatchQueue.main.async { if !coord.parent.focused, tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) } }
        }
    }

    /// Tall enough for every line at the offered width, up to `maxHeight`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = context.coordinator.textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let width = proposal.width ?? 240
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: font)
        let used = max(line, lm.usedRect(for: tc).height)
        return CGSize(width: width, height: min(maxHeight, ceil(used)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorText
        weak var textView: EditorTextView?
        init(_ p: EditorText) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
        }

        func focusChanged(_ on: Bool) {
            // after the current update pass, never inside it
            DispatchQueue.main.async { if self.parent.focused != on { self.parent.focused = on } }
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.cancelOperation(_:)):
                tv.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)) where parent.singleLine:
                let s = tv.string as NSString
                let at = tv.selectedRange().location
                parent.onReturn?(s.substring(to: at), s.substring(from: at))
                return true
            default:
                return false
            }
        }
    }
}

// ── A title over a body: the note sheet ─────────────────────────────────────

/// A title line over a body, as one sheet. Enter in the title moves the rest
/// of the line to the top of the body and carries on typing there.
struct NoteSheet: View {
    enum Field { case title, body }
    @Binding var title: String
    @Binding var text: String
    @Binding var focus: Field?
    var titlePrompt = "Title"
    var bodyPrompt = "Write a note"
    var bodyMax: CGFloat = 220
    /// False while the note is open to read: the chosen block holds the keyboard but nothing changes.
    var editable = true
    /// Where the cursor lands when typing moves in from outside.
    var caret: Int? = nil
    /// A click on a block that is open to read.
    var onClickReadOnly: ((Field) -> Void)? = nil
    /// The body's formatting keys and pasted pictures, handled by whoever owns the sheet.
    var onSave: (() -> Void)? = nil
    var onStep: ((Int) -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onImage: ((Data, EditorTextView) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholder(titlePrompt, empty: title.isEmpty, size: 13, weight: .semibold) {
                EditorText(text: $title, focused: bind(.title), font: .systemFont(ofSize: 13 * UIScale.text, weight: .semibold),
                           singleLine: true, onReturn: { before, after in
                               let r = InputRules.splitTitle(before: before, after: after, body: text)
                               title = r.title; text = r.body; focus = .body
                           }, editable: editable, caret: caret, onClickReadOnly: { onClickReadOnly?(.title) })
            }
            .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 5)
            .keyRing(!editable && focus == .title, radius: 5)
            Divider().opacity(0.5).padding(.horizontal, 8)
            placeholder(bodyPrompt, empty: text.isEmpty, size: 12, weight: .regular) {
                EditorText(text: $text, focused: bind(.body), font: .systemFont(ofSize: 12 * UIScale.text), maxHeight: bodyMax,
                           caretAtStart: true, editable: editable, caret: caret, onClickReadOnly: { onClickReadOnly?(.body) },
                           onSave: onSave, onStep: onStep, onDelete: onDelete, onImage: onImage)
                    .frame(minHeight: 54, alignment: .top)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .keyRing(!editable && focus == .body, radius: 5)
        }
    }

    private func bind(_ f: Field) -> Binding<Bool> {
        Binding(get: { focus == f }, set: { on in
            if on { focus = f } else if focus == f { focus = nil }
        })
    }

    private func placeholder<V: View>(_ p: String, empty: Bool, size: CGFloat, weight: Font.Weight, @ViewBuilder _ v: () -> V) -> some View {
        ZStack(alignment: .topLeading) {
            if empty { Text(p).font(.sb(size, weight: weight)).foregroundStyle(.tertiary).allowsHitTesting(false) }
            v()
        }
    }
}

// ── The colour dot ──────────────────────────────────────────────────────────

/// A thing's one colour, shown and chosen in one place: the dot. A click (or
/// Return, when the keyboard is on it) opens the colours as a grid four wide;
/// no colour is a faint grey ring. Arrows move in the grid, Return or a
/// digit picks (0 is none), Escape closes. Notes pass their own palette.
struct ColorDot: View {
    @Binding var selection: String?
    var allowNone = true
    var size: CGFloat = 10
    /// Lets the owner open it from the keyboard.
    var isOpen: Binding<Bool>? = nil
    /// The colours on offer: the timers' eight unless the caller brings its own.
    var palette: [(String, Color)] = timerColors
    @State private var open = false

    var body: some View {
        let shown = isOpen ?? $open
        Button { shown.wrappedValue.toggle() } label: {
            Group {
                if let s = selection, let c = palette.first(where: { $0.0 == s || $0.0 == tagColorName(s) })?.1 { Circle().fill(c) }
                else { Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.2).background(Circle().fill(Color.primary.opacity(0.06))) }
            }
            .frame(width: size, height: size)
            .padding(3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(selection.map { "\(tagColorName($0) ?? $0); click to change it" } ?? "No colour; click to choose one")
        .popover(isPresented: shown, arrowEdge: .bottom) {
            ColorGrid(selection: $selection, allowNone: allowNone, palette: palette, dismiss: { shown.wrappedValue = false })
        }
    }
}

/// The colours in rows of four, plus "none", for the dot's popover.
struct ColorGrid: View {
    @Binding var selection: String?
    let allowNone: Bool
    var palette: [(String, Color)] = timerColors
    let dismiss: () -> Void
    @State private var at = 0
    @FocusState private var focused: Bool

    private var count: Int { palette.count }
    private var rows: Int { (count + 3) / 4 }
    /// The place "No colour" holds in the walk, after the last dot.
    private var none: Int { count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<rows, id: \.self) { r in
                    GridRow {
                        ForEach(0..<4, id: \.self) { c in
                            let i = r * 4 + c
                            if i < count {
                                let (name, color) = palette[i]
                                Circle().fill(color).frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(selection == name ? 0.85 : 0), lineWidth: 2).padding(-3))
                                    .keyRing(at == i, radius: 11)
                                    .contentShape(Circle())
                                    .onTapGesture { pick(name) }
                                    .help("\(i + 1)")
                                    .accessibilityLabel(name)
                            } else {
                                Color.clear.frame(width: 16, height: 16)
                            }
                        }
                    }
                }
            }
            if allowNone {
                Button { pick(nil) } label: {
                    HStack(spacing: 5) {
                        Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.2).frame(width: 10, height: 10)
                        Text("No colour").font(.sb(11))
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .keyRing(at == none, radius: 5)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("0")
            }
        }
        .padding(10)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            at = selection.flatMap { s in palette.firstIndex { $0.0 == s || $0.0 == tagColorName(s) } } ?? 0
            focused = true
        }
        .onKeyPress(.leftArrow) { at = at == none ? count - 1 : (at % 4 == 0 ? at : at - 1); return .handled }
        .onKeyPress(.rightArrow) { at = at == none ? none : (at % 4 == 3 || at == count - 1 ? at : at + 1); return .handled }
        .onKeyPress(.upArrow) { at = at == none ? max(0, (rows - 1) * 4) : (at >= 4 ? at - 4 : at); return .handled }
        .onKeyPress(.downArrow) { at = at + 4 < count ? at + 4 : (allowNone ? none : at); return .handled }
        .onKeyPress(.return) { pick(at == none ? nil : palette[at].0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(characters: .decimalDigits) { k in
            guard let n = Int(k.characters), n <= count, n > 0 || allowNone else { return .ignored }
            pick(n == 0 ? nil : palette[n - 1].0)
            return .handled
        }
    }

    private func pick(_ name: String?) {
        selection = name
        dismiss()
    }
}

// ── Colour balls ────────────────────────────────────────────────────────────

/// The eight colour balls; the chosen one carries a ring. Colours are only
/// ever shown, never named.
struct ColorBalls: View {
    @Binding var selection: String?
    /// A note may have no colour: tapping the chosen ball again clears it. A timer always has one.
    var allowNone = false
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 7) {
            ForEach(timerColors, id: \.0) { name, c in
                Circle().fill(c).frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(selection == name ? 0.8 : 0), lineWidth: 2).padding(-3))
                    .contentShape(Circle())
                    .onTapGesture { selection = (allowNone && selection == name) ? nil : name }
                    .accessibilityLabel(name)
            }
        }
        .padding(3)
    }
}
