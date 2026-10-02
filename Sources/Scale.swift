// Scale.swift
// How big Switchboard draws everything, chosen in Settings: Small for a laptop,
// Medium for a wide monitor at arm's length, Large for a screen share. One
// choice moves every surface (panel, hover card, Sessions, windows, the
// menu-bar icon) together. Text grows most; icons a little less and inputs
// and spacing least, so a control never looks swollen beside its label.

import AppKit
import SwiftUI

enum UISize: String, CaseIterable {
    case sm, md, lg

    var title: String {
        switch self { case .sm: return "Small"; case .md: return "Medium"; case .lg: return "Large" }
    }
    var detail: String {
        switch self {
        case .sm: return "for a laptop screen"
        case .md: return "comfortable on a wide monitor"
        case .lg: return "readable in a screen share"
        }
    }
    /// How much text grows.
    var text: CGFloat { switch self { case .sm: return 1; case .md: return 1.18; case .lg: return 1.36 } }
    /// Icons follow text most of the way, so a glyph stays level with the word beside it.
    var icon: CGFloat { 1 + (text - 1) * 0.85 }
    /// Inputs, padding and gaps grow least: a bigger field, not a bloated one.
    var control: CGFloat { 1 + (text - 1) * 0.6 }
}

/// The size in force; views read the static factors while they draw, and the
/// roots redraw from scratch when the size changes.
final class UIScale: ObservableObject {
    static let shared = UIScale()
    static let key = "switchboard.uiSize"
    @Published var size: UISize = UISize(rawValue: UserDefaults.standard.string(forKey: UIScale.key) ?? "") ?? .sm {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: Self.key) }
    }
    /// A probe or snapshot can draw at a size without touching the saved choice.
    static var override: UISize?
    static var current: UISize { override ?? shared.size }
    static var text: CGFloat { current.text }
    static var icon: CGFloat { current.icon }
    static var control: CGFloat { current.control }

    /// Small controls stay small at Medium and step up one size at Large.
    static func controlSize(_ c: ControlSize) -> ControlSize {
        guard current == .lg else { return c }
        switch c {
        case .mini: return .small
        case .small: return .regular
        default: return c
        }
    }
}

extension Font {
    /// Text at the chosen size.
    static func sb(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * UIScale.text, weight: weight)
    }
    /// An icon at the chosen size: a touch smaller step than text.
    static func sbIcon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * UIScale.icon, weight: weight)
    }
}

/// A width or column that holds text, at the chosen size.
func sw(_ v: CGFloat) -> CGFloat { (v * UIScale.text).rounded() }
/// A width that holds an icon.
func si(_ v: CGFloat) -> CGFloat { (v * UIScale.icon).rounded() }
/// Padding, gaps and control lengths.
func sc(_ v: CGFloat) -> CGFloat { (v * UIScale.control).rounded() }

extension View {
    /// Small controls stay small at Medium and grow one step at Large.
    func sbControlSize(_ c: ControlSize) -> some View { controlSize(UIScale.controlSize(c)) }
}

/// Redraws its content from scratch when the size changes, so every static
/// size read in a body is read again.
struct ScaledRoot<Content: View>: View {
    @ObservedObject private var scale = UIScale.shared
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View { content.id(scale.size) }
}

/// The size rules without drawing anything.
func probeScale() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    check("Small draws everything at its designed size", UISize.sm.text == 1 && UISize.sm.icon == 1 && UISize.sm.control == 1)
    check("each step grows text more than icons, and icons more than inputs",
          UISize.allCases.allSatisfy { $0 == .sm || ($0.text > $0.icon && $0.icon > $0.control) })
    check("Large is bigger than Medium in every measure",
          UISize.lg.text > UISize.md.text && UISize.lg.icon > UISize.md.icon && UISize.lg.control > UISize.md.control)
    let before = UIScale.override
    UIScale.override = .lg
    check("small controls step up one size at Large", UIScale.controlSize(.small) == .regular && UIScale.controlSize(.mini) == .small)
    check("a 12-point label is about 16 at Large", abs(12 * UIScale.text - 16.3) < 0.1, "\(12 * UIScale.text)")
    UIScale.override = .md
    check("controls keep their size at Medium", UIScale.controlSize(.small) == .small)
    UIScale.override = before
    return lines
}
