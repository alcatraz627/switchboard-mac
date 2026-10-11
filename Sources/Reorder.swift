// Reorder.swift
// Drag to reorder, shared by every list the owner arranges by hand (bulbs,
// notes). Each row gets a grip; while a row is dragged the others move out of
// its way at once, so the new order is visible before the drop.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReorderStack<Item: Identifiable, Row: View>: View where Item.ID == String {
    let items: [Item]
    /// Move the dragged item to where `target` is now. Called as the drag
    /// passes over each row, so the list rearranges live.
    let move: (_ dragged: String, _ target: String) -> Void
    /// Called once when a drag ends, to save the new order.
    var commit: () -> Void = {}
    let row: (_ index: Int, _ item: Item, _ grip: AnyView) -> Row
    @State private var dragging: String?

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
            row(i, item, AnyView(grip(item.id)))
                .opacity(dragging == item.id ? 0.35 : 1)
                .onDrop(of: [UTType.text], delegate: ReorderDrop(target: item.id, dragging: $dragging,
                                                                 move: move, commit: commit))
        }
    }

    private func grip(_ id: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.sbIcon(10, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: si(14), height: si(20))
            .contentShape(Rectangle())
            .onDrag {
                dragging = id
                watchDragEnd()
                return NSItemProvider(object: id as NSString)
            }
            .help("Drag to reorder")
    }

    /// A drop outside every row, or Esc, never reaches performDrop. Once the
    /// button is up, a drag still marked live is ended here and its order saved.
    private func watchDragEnd() {
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            t.invalidate()
            DispatchQueue.main.async {
                guard dragging != nil else { return }   // performDrop already finished it
                dragging = nil
                commit()
            }
        }
    }
}

private struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(Motion.fast) { move(d, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        commit()
        return true
    }
}

/// The ordering under drag and drop, checked without a pointer.
func probeReorder() -> [String] {
    struct I: Identifiable { let id: String }
    func line(_ name: String, _ ok: Bool, _ got: String) -> String { "\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got: \(got))")" }
    let down = reordered(["a", "b", "c", "d"], moving: "a", to: "c")
    let up = reordered(["a", "b", "c", "d"], moving: "d", to: "b")
    let saved = applyOrder([I(id: "x"), I(id: "b"), I(id: "a")], ["a", "b"]).map(\.id)
    var out = [line("dragging down lands on the target's place", down == ["b", "c", "a", "d"], down.joined()),
               line("dragging up lands on the target's place", up == ["a", "d", "b", "c"], up.joined()),
               line("a saved order applies; new items go last", saved == ["a", "b", "x"], saved.joined())]

    // The shared order: the seven vectors every port of between() must pass (specs/order.md).
    let vectors: [(String, String?, String)] = [("", nil, "i"), ("i", nil, "r"), ("", "i", "9"), ("a", "b", "ai"),
                                                ("a", "ai", "a9"), ("az", "b", "azi"), ("1", "2", "1i")]
    for (a, b, want) in vectors {
        let got = NotePos.between(a, b)
        out.append(line("between(\"\(a)\", \(b.map { "\"\($0)\"" } ?? "none")) is \(want)", got == want, got))
    }
    var hi = "b", keys: [String] = []
    for _ in 0..<20 { let k = NotePos.between("a", hi); keys.append(k); hi = k }   // each lands in the gap just above "a"
    out.append(line("twenty inserts into one gap stay in order and never end in 0",
                    zip(keys, keys.dropFirst()).allSatisfy { $0 > $1 } && keys.allSatisfy { $0.last != "0" && $0 > "a" }, keys.suffix(2).joined(separator: " ")))
    let sp = NotePos.spread(5)
    out.append(line("spread(5) is five ascending three-character-or-less keys", sp.count == 5 && sp == sp.sorted() && Set(sp).count == 5 && sp.allSatisfy { $0.count <= 3 && $0.last != "0" }, sp.joined(separator: ",")))
    let fresh = NotePos.fresh(4, below: "3")
    out.append(line("fresh keys all sit above the first arranged note", fresh.count == 4 && fresh == fresh.sorted() && fresh.allSatisfy { $0 < "3" }, fresh.joined(separator: ",")))
    out.append(line("only 0-9a-z, not ending in 0, is a usable bound",
                    NotePos.usable("i") && NotePos.usable("a9") && NotePos.usable("null") && !NotePos.usable("no_") && !NotePos.usable("a0")
                    && !NotePos.usable("Z") && !NotePos.usable("") && !NotePos.usable(nil), ""))

    // The one comparator: pinned first, never-arranged above arranged (newest first), then pos in byte order, then id.
    func note(_ id: String, day: Int, pos: String? = nil, pinned: Bool = false) -> Note {
        var n = Note(id: id, title: id, body: "", tags: [], created: Date(timeIntervalSince1970: Double(day) * 86400))
        n.pos = pos; n.pinned = pinned
        return n
    }
    let set = [note("arr-b", day: 9, pos: "r"), note("arr-a", day: 1, pos: "9"), note("new-old", day: 2), note("new-new", day: 8),
               note("pin-b", day: 1, pos: "r", pinned: true), note("pin-new", day: 5, pinned: true), note("tie-b", day: 3, pos: "m"), note("tie-a", day: 3, pos: "m")]
    let sorted = NoteOrder.sorted(set).map(\.id)
    out.append(line("the comparator puts pinned first, unarranged newest first, then pos, then id",
                    sorted == ["pin-new", "pin-b", "new-new", "new-old", "arr-a", "tie-a", "tie-b", "arr-b"], sorted.joined(separator: ",")))
    out.append(line("pos 'Z' sorts by bytes, after '9' and before 'a'", NoteOrder.sorted([note("x", day: 1, pos: "a"), note("y", day: 1, pos: "Z"), note("z", day: 1, pos: "9")]).map(\.id) == ["z", "y", "x"], ""))

    // `pos` is read as the exact text, whatever it looks like to YAML.
    for raw in ["no", "1e5", "null", "i", "a9"] {
        let n = NotesStore.parse(id: "p", "---\ntitle: \"P\"\npos: \(raw)\n---\nbody\n")
        let back = n.map(NotesStore.render) ?? ""
        out.append(line("pos: \(raw) reads back as exactly that text and is written bare", n?.pos == raw && back.contains("\npos: \(raw)\n"), "\(n?.pos ?? "nil")"))
    }
    let after = NotesStore.parse(id: "q", "---\ntitle: \"Q\"\nurl: \"https://x.y\"\npos: i\nmood: calm\n---\nb\n").map(NotesStore.render) ?? ""
    out.append(line("pos is written after url and before unknown keys", after.contains("url: \"https://x.y\"\npos: i\nmood: calm\n"), after))
    out.append(line("a note without pos writes no pos line", !(NotesStore.parse(id: "r", "---\ntitle: \"R\"\n---\nb\n").map(NotesStore.render) ?? "").contains("pos:"), ""))
    return out
}

/// Sorts items by a saved id order; ones not in it keep their order at the end.
func applyOrder<T: Identifiable>(_ items: [T], _ order: [String]) -> [T] where T.ID == String {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return items.enumerated().sorted { a, b in
        (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
    }.map(\.element)
}
