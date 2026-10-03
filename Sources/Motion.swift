// Motion.swift
// How things move in Switchboard. Motion says what happened to a thing, with
// four verbs and nothing else: arrive, leave, change, attention. The curve and
// the two speeds are the hub's own, so a session feels the same in the browser
// and under the menu bar. With Reduce Motion on, every verb shows its still form.
// The direction and its reasons: docs/plans/20261003-animation-direction.md

import AppKit
import SwiftUI

enum Motion {
    /// The hub's --t-fast and --t-slow, and its cubic-bezier(.2, 0, 0, 1).
    static let fastTime = 0.13
    static let slowTime = 0.26

    /// True when macOS asks for less motion; every verb then shows its still form.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A value or a state changed, or a small thing moved.
    static var fast: Animation? { reduced ? nil : .timingCurve(0.2, 0, 0, 1, duration: fastTime) }
    /// Something arrived or left.
    static var slow: Animation? { reduced ? nil : .timingCurve(0.2, 0, 0, 1, duration: slowTime) }

    /// Arrive: lifts 4 points into place as it fades in. Leave: fades out where it was.
    static var arrive: AnyTransition {
        reduced ? .identity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity)
    }

    /// A page turn: the new page comes in a short way from the side it lies on.
    static func turn(forward: Bool) -> AnyTransition {
        guard !reduced else { return .identity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 14 : -14)), removal: .opacity)
    }

    /// The attention ring, as the hub draws it: two beats, then gone.
    static let beats: [(at: Double, on: Bool)] = [(0, true), (0.32, false), (0.55, true), (0.95, false)]
}

/// Attention: the hub's accent ring around a row, two beats. Reduce Motion
/// shows one steady ring for the same time instead.
struct AttentionRing: ViewModifier {
    var lit: Bool
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(lit ? 0.85 : 0), lineWidth: 2)
                .padding(-1)
                .allowsHitTesting(false)
        )
    }
}

/// A working session's dot: a ring that swells and fades every two seconds,
/// the hub's pulse. Still under Reduce Motion, since the colour already says it.
struct AlivePulse: View {
    let color: Color
    let size: CGFloat
    @State private var on = false
    var body: some View {
        Circle().stroke(color, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(on ? 2.1 : 1)
            .opacity(on ? 0 : 0.7)
            .onAppear {
                guard !Motion.reduced else { return }
                withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 2).repeatForever(autoreverses: false)) { on = true }
            }
            .allowsHitTesting(false)
    }
}
