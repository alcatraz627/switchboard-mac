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
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: 20)
            .contentShape(Rectangle())
            .onDrag {
                dragging = id
                return NSItemProvider(object: id as NSString)
            }
            .help("Drag to reorder")
    }
}

private struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.easeInOut(duration: 0.16)) { move(d, target) }
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
    return [line("dragging down lands on the target's place", down == ["b", "c", "a", "d"], down.joined()),
            line("dragging up lands on the target's place", up == ["a", "d", "b", "c"], up.joined()),
            line("a saved order applies; new items go last", saved == ["a", "b", "x"], saved.joined())]
}

/// Moves `dragged` to `target`'s place in an id order.
func reordered(_ order: [String], moving dragged: String, to target: String) -> [String] {
    guard let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target), from != to else { return order }
    var o = order
    o.remove(at: from)
    o.insert(dragged, at: to)
    return o
}

/// Sorts items by a saved id order; ones not in it keep their order at the end.
func applyOrder<T: Identifiable>(_ items: [T], _ order: [String]) -> [T] where T.ID == String {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return items.enumerated().sorted { a, b in
        (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
    }.map(\.element)
}
