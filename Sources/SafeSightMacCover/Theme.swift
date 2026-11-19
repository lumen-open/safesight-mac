// SPDX-License-Identifier: Apache-2.0
// Every colour the covers, the way-out line and the repair card use, in one place so they can change later.
// The tentative colour identity is "Lumen" (owner, 19 November 2026): a cool teal on clean white. Covers stay
// calm and neutral; the teal is only for accents, such as the key caps.
//
// Covers are opaque. A system material (NSVisualEffectView) would blend in what lies under the cover, so
// covers are opaque flat fills instead, a neutral close to the system's own window backgrounds.
import AppKit
import CoreGraphics

public struct CoverTheme: Equatable, Sendable {
    /// An opaque sRGB colour.
    public struct RGB: Equatable, Sendable {
        public let r: UInt8, g: UInt8, b: UInt8
        public init(_ hex: UInt32) { r = UInt8(hex >> 16 & 0xFF); g = UInt8(hex >> 8 & 0xFF); b = UInt8(hex & 0xFF) }
        public func cg(_ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
        }
        /// WCAG relative luminance.
        public var luminance: Double {
            func lin(_ c: UInt8) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        /// WCAG contrast ratio between two colours.
        public func contrast(_ o: RGB) -> Double {
            let a = luminance, b = o.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    public let isDark: Bool
    // The Lumen palette.
    public let background: RGB, card: RGB, text: RGB, muted: RGB, line: RGB
    public let accent: RGB, accentPressed: RGB, onAccent: RGB, softAccent: RGB
    /// Covers: one calm neutral, never teal.
    public let cover: RGB
    // Key caps on the way-out line.
    public let keyFill: RGB, keyEdge: RGB, keyText: RGB
    /// The way-out line's soft shadow.
    public let shadowAlpha: CGFloat

    public static let light = CoverTheme(
        isDark: false,
        background: RGB(0xF3F6F6), card: RGB(0xFFFFFF), text: RGB(0x0E1B1D), muted: RGB(0x56686B), line: RGB(0xDDE6E6),
        accent: RGB(0x0B7F73), accentPressed: RGB(0x086A60), onAccent: RGB(0xFFFFFF), softAccent: RGB(0xDCF1EE),
        cover: RGB(0xE6ECEC),
        keyFill: RGB(0xDCF1EE), keyEdge: RGB(0xA9D6CF), keyText: RGB(0x086A60),
        shadowAlpha: 0.10)

    public static let dark = CoverTheme(
        isDark: true,
        background: RGB(0x0B1112), card: RGB(0x121A1C), text: RGB(0xECF4F3), muted: RGB(0x97AAA8), line: RGB(0x22322F),
        accent: RGB(0x4FD8C4), accentPressed: RGB(0x3CC6B2), onAccent: RGB(0x06201C), softAccent: RGB(0x123430),
        cover: RGB(0x0E1516),
        keyFill: RGB(0x123430), keyEdge: RGB(0x2A6B61), keyText: RGB(0x4FD8C4),
        shadowAlpha: 0.45)

    /// The theme for an appearance: dark for any dark appearance, light otherwise.
    public static func forAppearance(_ a: NSAppearance?) -> CoverTheme {
        a?.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]).map { $0 == .aqua ? light : dark } ?? light
    }

    /// The theme for the system's current appearance.
    @MainActor public static var current: CoverTheme { forAppearance(NSApp?.effectiveAppearance) }
}
