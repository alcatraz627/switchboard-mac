// ScrollSteps.swift
// Scrolling over a thing adjusts that thing: over a row of tabs it moves to
// the next tab, over a slider it moves the slider by 5%. Each such place
// registers where it is on the panel; one scroll watcher on the panel finds
// the place under the pointer and turns the movement into whole steps.

import AppKit
import SwiftUI

/// Turns wheel and trackpad movement into whole steps, so a scroll moves
/// one tab or one notch at a time rather than racing.
struct ScrollStepper {
    /// Where a trackpad or Magic Mouse gesture is; a mouse wheel has none.
    enum Phase { case none, began, changed, ended }

    /// One step per swipe however long it runs (the hover card), or one per
    /// `distance` points of travel (tabs, sliders).
    var perGesture: Bool
    /// Points of trackpad travel for one step.
    var distance: CGFloat
    /// The shortest gap between two wheel steps, so a fast spin steps rather than races.
    var wheelPause: TimeInterval
    /// Travel older than this belongs to an earlier gesture and is forgotten.
    static let staleAfter: TimeInterval = 0.5

    private var acc: CGFloat = 0
    private var lastStep: TimeInterval = -.infinity
    private var lastEvent: TimeInterval = -.infinity
    private var steppedThisGesture = false

    init(perGesture: Bool, distance: CGFloat, wheelPause: TimeInterval) {
        self.perGesture = perGesture; self.distance = distance; self.wheelPause = wheelPause
    }

    /// One scroll event; +1 forward, -1 back, 0 for no step yet. Content-style
    /// direction: scrolling the way that moves a list down goes forward.
    mutating func step(delta: CGFloat, precise: Bool, phase: Phase, momentum: Bool, at t: TimeInterval) -> Int {
        if momentum { return 0 }                    // inertia after the finger lifts moves nothing
        guard delta != 0 || phase != .none else { return 0 }
        if !precise {
            guard delta != 0, t - lastStep >= wheelPause else { return 0 }
            lastStep = t
            return delta < 0 ? 1 : -1
        }
        if phase == .began || t - lastEvent > Self.staleAfter { acc = 0; steppedThisGesture = false }
        lastEvent = t
        if phase == .ended { acc = 0; steppedThisGesture = false; return 0 }
        guard !(perGesture && steppedThisGesture) else { return 0 }
        acc += delta
        guard abs(acc) >= distance else { return 0 }
        let s = acc < 0 ? 1 : -1
        acc = 0
        steppedThisGesture = true
        lastStep = t
        return s
    }

    mutating func reset() { acc = 0; lastStep = -.infinity; lastEvent = -.infinity; steppedThisGesture = false }

    /// The steppers in use, tuned so tabs follow a swipe without racing and a
    /// slider moves 5% a notch without crawling.
    static func tabs() -> ScrollStepper { ScrollStepper(perGesture: false, distance: 28, wheelPause: 0.12) }
    static func slider() -> ScrollStepper { ScrollStepper(perGesture: false, distance: 10, wheelPause: 0.03) }
}

extension ScrollStepper.Phase {
    init(_ e: NSEvent) {
        self = e.phase.contains(.began) ? .began
            : e.phase.contains(.ended) || e.phase.contains(.cancelled) ? .ended
            : e.phase.isEmpty ? .none : .changed
    }
}

/// The places on the panel that take scroll steps, by name, with where each
/// sits. Content places only count inside the visible part of the scrolling
/// content, so one scrolled out of sight under the header never catches a scroll.
final class ScrollTargets {
    static let shared = ScrollTargets()
    /// The hover card's own places (its sliders), in the card's window.
    static let card = ScrollTargets()
    static let stepped = Notification.Name("switchboard.scrollStep")
    static let space = "panel"
    static let cardSpace = "quickCard"

    struct Target {
        var frame: CGRect
        var inContent: Bool
        var stepper: ScrollStepper
    }
    private(set) var targets: [String: Target] = [:]
    /// The visible part of the panel's scrolling content.
    var contentFrame: CGRect = .null

    func set(_ id: String, frame: CGRect, inContent: Bool, stepper: @autoclosure () -> ScrollStepper) {
        if targets[id] == nil { targets[id] = Target(frame: frame, inContent: inContent, stepper: stepper()) }
        else { targets[id]?.frame = frame }
    }
    func remove(_ id: String) { targets[id] = nil }

    /// The target under a point, header places first.
    func target(at p: CGPoint) -> String? {
        if let hit = targets.first(where: { !$0.value.inContent && $0.value.frame.contains(p) }) { return hit.key }
        guard contentFrame.contains(p) else { return nil }
        return targets.first { $0.value.inContent && $0.value.frame.contains(p) }?.key
    }

    /// Handles a scroll at a point on the panel; true when a target took it,
    /// whether or not it was a whole step yet. A step is posted by name.
    func handle(_ e: NSEvent, at p: CGPoint) -> Bool {
        guard let id = target(at: p) else { return false }
        // sideways travel counts too, for a trackpad swipe along a row of tabs
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        let s = targets[id]!.stepper.step(delta: d, precise: e.hasPreciseScrollingDeltas, phase: .init(e),
                                         momentum: !e.momentumPhase.isEmpty, at: e.timestamp)
        if s != 0 { NotificationCenter.default.post(name: Self.stepped, object: id, userInfo: ["step": s]) }
        return true
    }
}

extension View {
    /// Makes this view a place that takes scroll steps; `act` gets +1 or -1.
    /// `onCard` registers it with the hover card instead of the panel.
    func scrollSteps(_ id: String, inContent: Bool = false, onCard: Bool = false,
                     stepper: @escaping @autoclosure () -> ScrollStepper = .tabs(),
                     _ act: @escaping (Int) -> Void) -> some View {
        let targets = onCard ? ScrollTargets.card : ScrollTargets.shared
        return background(GeometryReader { g in
            let f = g.frame(in: .named(onCard ? ScrollTargets.cardSpace : ScrollTargets.space))
            Color.clear
                .onAppear { targets.set(id, frame: f, inContent: inContent, stepper: stepper()) }
                .onChange(of: f) { nf in targets.set(id, frame: nf, inContent: inContent, stepper: stepper()) }
                .onDisappear { targets.remove(id) }
        })
        .onReceive(NotificationCenter.default.publisher(for: ScrollTargets.stepped)) { n in
            guard n.object as? String == id, let s = n.userInfo?["step"] as? Int else { return }
            act(s)
        }
    }

    /// Marks the visible frame of the panel's scrolling content.
    func scrollContentFrame() -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named(ScrollTargets.space))
            Color.clear
                .onAppear { ScrollTargets.shared.contentFrame = f }
                .onChange(of: f) { nf in ScrollTargets.shared.contentFrame = nf }
        })
    }
}

/// The next item in a list, `by` places along, stopping at either end.
func stepped<T: Equatable>(_ items: [T], from current: T, by: Int) -> T? {
    guard let i = items.firstIndex(of: current) else { return items.first }
    let j = i + by
    return items.indices.contains(j) ? items[j] : nil
}

/// A slider value moved one scroll step: 5%, kept within 0 and 1.
func sliderStep(_ v: Float, by: Int) -> Float { max(0, min(1, ((v * 20).rounded() + Float(by)) / 20)) }
