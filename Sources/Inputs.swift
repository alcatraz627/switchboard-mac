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
    static func canSave(title: String, body: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The copy buttons a note row offers: the body's copy only when there is
    /// a body, the title's only when there is a title.
    static func copyButtons(title: String, body: String) -> (body: Bool, title: Bool) {
        (!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !title.trimmingCharacters(in: .whitespaces).isEmpty)
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
        tv.delegate = context.coordinator
        tv.onFocus = { [weak coord = context.coordinator] on in coord?.focusChanged(on) }
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
        let has = tv.window?.firstResponder === tv
        if focused && !has {
            DispatchQueue.main.async {
                guard let w = tv.window, w.firstResponder !== tv else { return }
                w.makeFirstResponder(tv)
                if caretAtStart { tv.setSelectedRange(NSRange(location: 0, length: 0)) }
            }
        } else if !focused && has {
            DispatchQueue.main.async { if tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) } }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholder(titlePrompt, empty: title.isEmpty, size: 13, weight: .semibold) {
                EditorText(text: $title, focused: bind(.title), font: .systemFont(ofSize: 13 * UIScale.text, weight: .semibold),
                           singleLine: true, onReturn: { before, after in
                               let r = InputRules.splitTitle(before: before, after: after, body: text)
                               title = r.title; text = r.body; focus = .body
                           })
            }
            .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 5)
            Divider().opacity(0.5).padding(.horizontal, 8)
            placeholder(bodyPrompt, empty: text.isEmpty, size: 12, weight: .regular) {
                EditorText(text: $text, focused: bind(.body), font: .systemFont(ofSize: 12 * UIScale.text), maxHeight: bodyMax, caretAtStart: true)
                    .frame(minHeight: 54, alignment: .top)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
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
