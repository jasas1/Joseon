import AppKit
import SwiftUI
import JoseonRender

/// App colors. They come from the render Theme so the shell and the panels read as one system.
enum Palette {
    /// Theme for the panels. Increase Contrast makes grid and text stronger.
    static func theme(highContrast: Bool) -> Theme {
        var t = Theme()
        if highContrast {
            t.grid = SIMD4<Float>(0.62, 0.72, 0.90, 0.55)
            t.text = SIMD4<Float>(1, 1, 1, 1)
            t.background = SIMD4<Float>(0.0, 0.0, 0.02, 1)
        }
        return t
    }

    static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func nsColor(_ v: SIMD4<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: CGFloat(v.w))
    }

    static var current: Theme { theme(highContrast: highContrast) }

    static var background: NSColor { nsColor(current.background) }
    static var panel: NSColor { nsColor(current.panel) }
    static var cardBorder: NSColor { highContrast ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 1, alpha: 0.08) }
    static var text: NSColor { nsColor(current.text) }
    static var secondaryText: NSColor { highContrast ? NSColor(white: 1, alpha: 0.9) : nsColor(current.text).withAlphaComponent(0.62) }
    static var accent: NSColor { nsColor(current.accent) }
    static var warn: NSColor { nsColor(current.warn) }
    static var danger: NSColor { nsColor(current.danger) }
    static let live = NSColor(srgbRed: 0.25, green: 0.85, blue: 0.45, alpha: 1)
    static let demo = NSColor(srgbRed: 0.72, green: 0.55, blue: 1.0, alpha: 1)
    /// Menu bar mini graph, "Orange". Reads on a light and on a dark menu bar.
    static let miniGraphOrange = NSColor(srgbRed: 1.0, green: 0.58, blue: 0.10, alpha: 1)
}

extension Color {
    static var joseonBackground: Color { Color(nsColor: Palette.background) }
    static var joseonPanel: Color { Color(nsColor: Palette.panel) }
    static var joseonText: Color { Color(nsColor: Palette.text) }
    static var joseonSecondary: Color { Color(nsColor: Palette.secondaryText) }
    static var joseonAccent: Color { Color(nsColor: Palette.accent) }
    static var joseonWarn: Color { Color(nsColor: Palette.warn) }
    static var joseonDanger: Color { Color(nsColor: Palette.danger) }
}
