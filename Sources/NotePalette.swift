// NotePalette.swift
// The colour dots a note can wear. They start as the shared eight (the same
// names the Pi and the phone know) and can be added to, renamed, recoloured
// and removed in Settings > Desk > Notes. Timers keep their own eight.

import AppKit
import SwiftUI

/// One dot. `key` is what a note's file stores and never changes, so a rename
/// only changes the label shown here; `hex` is nil for a built-in system colour.
struct NoteDot: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var hex: String?
    var id: String { key }
}

final class NotePalette: ObservableObject {
    static let shared = NotePalette()
    /// Kept in the state folder, so a test run pointed at a scratch folder never touches the owner's set.
    static var path: String { AppPaths.stateDir + "/note-palette.json" }
    /// Enough to fill a grid and still pick by eye; more is a different tool.
    static let maxDots = 16

    @Published private(set) var dots: [NoteDot]

    /// The shared eight, in their order.
    static var eight: [NoteDot] { timerColors.map { NoteDot(key: $0.0, label: $0.0.capitalized, hex: nil) } }

    init() {
        dots = Self.read() ?? Self.eight
    }

    private static func read() -> [NoteDot]? {
        guard let d = FileManager.default.contents(atPath: path),
              let list = try? JSONDecoder().decode([NoteDot].self, from: d), !list.isEmpty else { return nil }
        return list
    }

    private func save() {
        if dots == Self.eight { try? FileManager.default.removeItem(atPath: Self.path) }
        else if let d = try? JSONEncoder().encode(dots) { try? d.write(to: URL(fileURLWithPath: Self.path), options: .atomic) }
    }

    func reload() { dots = Self.read() ?? Self.eight }

    // ── Looking up ──

    /// The dots as the pickers and filters draw them: key and colour.
    var colors: [(String, Color)] { dots.map { ($0.key, Self.color(of: $0)) } }
    func dot(_ key: String) -> NoteDot? { dots.first { $0.key == key } }
    func color(_ key: String) -> Color? { dot(key).map(Self.color(of:)) }
    func label(_ key: String) -> String { dot(key)?.label ?? key }

    static func color(of d: NoteDot) -> Color {
        if let h = d.hex, let c = nsColor(hex: h) { return Color(nsColor: c) }
        return timerColor(d.key)
    }

    static func nsColor(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    static func hex(of c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .systemBlue
        func b(_ x: CGFloat) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", b(n.redComponent), b(n.greenComponent), b(n.blueComponent))
    }

    // ── Changing ──

    /// A name unused by any dot: the label as a lowercase word, numbered if taken.
    private func freshKey(from label: String) -> String {
        let base = label.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let root = base.isEmpty ? "colour" : base
        var key = root, n = 2
        while dots.contains(where: { $0.key == key }) { key = "\(root)-\(n)"; n += 1 }
        return key
    }

    @discardableResult
    func add(label: String, hex: String) -> NoteDot? {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, dots.count < Self.maxDots, Self.nsColor(hex: hex) != nil else { return nil }
        let d = NoteDot(key: freshKey(from: l), label: l, hex: hex)
        dots.append(d)
        save()
        return d
    }

    func rename(_ key: String, to label: String) {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, let i = dots.firstIndex(where: { $0.key == key }), dots[i].label != l else { return }
        dots[i].label = l
        save()
    }

    func recolor(_ key: String, hex: String) {
        guard Self.nsColor(hex: hex) != nil, let i = dots.firstIndex(where: { $0.key == key }), dots[i].hex != hex else { return }
        dots[i].hex = hex
        save()
    }

    /// Notes that wore it keep the name in their file and show no dot until it comes back.
    func remove(_ key: String) {
        guard dots.count > 1 else { return }
        dots.removeAll { $0.key == key }
        save()
    }

    func reset() {
        dots = Self.eight
        save()
    }
}

/// The colour names a note file may carry now: the shared eight's older names, then the palette's own.
func noteColorName(_ name: String) -> String? {
    let n = legacyTagColors[name] ?? name
    return NotePalette.shared.dot(n) != nil ? n : nil
}

/// The palette as a list of (name, colour), in the owner's order.
var noteColors: [(String, Color)] { NotePalette.shared.colors }
/// A note's dot colour, or the blue every unknown name falls to.
func noteColor(_ name: String) -> Color {
    noteColorName(name).flatMap { NotePalette.shared.color($0) } ?? Color(nsColor: .systemBlue)
}

// ── Settings: the dot list ──────────────────────────────────────────────────

/// The note colours as editable rows: change a colour, rename it, remove it, add another.
struct NoteDotsEditor: View {
    @ObservedObject var palette = NotePalette.shared
    @ObservedObject var notes = NotesStore.shared
    @State private var newLabel = ""
    @State private var newColor = Color(nsColor: .systemIndigo)
    @State private var pendingRemove: NoteDot?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: "Note colours")
            Text("The dots a note can wear. Renaming a dot changes only what you see here; the note's file keeps the original name, so the Pi and the phone still match.")
                .font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            Card {
                ForEach(Array(palette.dots.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    row(d)
                }
                Divider().padding(.leading, PT.rowH)
                addRow
            }
        }
        .task { if !notes.loaded { notes.load() } }
        .confirmationDialog(pendingRemove.map { "Remove \u{201C}\($0.label)\u{201D}?" } ?? "", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let d = pendingRemove { palette.remove(d.key) }; pendingRemove = nil }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            if let d = pendingRemove { Text("\(use(d.key)) show no dot until it is added again under the same name.") }
        }
    }

    private func count(_ key: String) -> Int { notes.notes.filter { $0.color.flatMap(noteColorName) == key }.count }
    private func use(_ key: String) -> String { let n = count(key); return n == 1 ? "1 note" : "\(n) notes" }

    private func row(_ d: NoteDot) -> some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(get: { NotePalette.color(of: d) }, set: { palette.recolor(d.key, hex: NotePalette.hex(of: $0)) }), supportsOpacity: false)
                .labelsHidden().help("Change this colour")
            DotNameField(text: d.label) { palette.rename(d.key, to: $0) }
            Spacer(minLength: 4)
            Text(use(d.key)).font(PT.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            Button { if count(d.key) > 0 { pendingRemove = d } else { palette.remove(d.key) } } label: {
                Label("Remove", systemImage: "trash").lineLimit(1).fixedSize()
            }
            .sbControlSize(.small).disabled(palette.dots.count <= 1).help("Remove this dot")
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, PT.rowV + 2)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: $newColor, supportsOpacity: false).labelsHidden().help("Colour of the new dot")
            TextField("Name a new dot", text: $newLabel).textFieldStyle(.plain).font(PT.label).inputBox(focused: false)
                .onSubmit(add)
            Spacer(minLength: 4)
            Button(action: add) { Label("Add", systemImage: "plus").lineLimit(1).fixedSize() }
                .sbControlSize(.small).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty || palette.dots.count >= NotePalette.maxDots)
                .help("Add a dot with this name and colour")
            Button { palette.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise").lineLimit(1).fixedSize() }
                .sbControlSize(.small).disabled(palette.dots == NotePalette.eight).help("Back to the shared eight")
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, PT.rowV + 2)
    }

    private func add() {
        guard palette.add(label: newLabel, hex: NotePalette.hex(of: newColor)) != nil else { return }
        newLabel = ""
    }
}

/// A dot's name as a text box that saves when Return is pressed or the box is left.
private struct DotNameField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft).textFieldStyle(.plain).font(PT.label)
            .focused($focused).inputBox(focused: focused)
            .frame(maxWidth: 160)
            .onAppear { draft = text }
            .onChange(of: text) { t in if !focused { draft = t } }
            .onSubmit { commit(draft) }
            .onChange(of: focused) { f in if !f { commit(draft); if draft.trimmingCharacters(in: .whitespaces).isEmpty { draft = text } } }
    }
}
