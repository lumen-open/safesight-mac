// SPDX-License-Identifier: Apache-2.0
// Every colour and typeface the covers, the way-out line, the repair card and the app's windows use, in one place.
// The identity is the "desert" study (DESIGN-desert.md): lime plaster and lamp-black by day,
// lapis night by night, malachite for the one accent, and gold leaf only as a rare hairline. Headings are in the
// system serif (New York); everything else stays in the system sans.
//
// Covers stay a calm, opaque, flat neutral with no ornament: no arch, no gold, no serif. A system material
// (NSVisualEffectView) would blend in what lies under the cover, so covers are opaque fills instead.
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
        public func ns(_ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
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
        /// How far the colour is from grey: its largest channel minus its smallest, in levels of 255.
        public var chroma: Int { Int(max(r, g, b)) - Int(min(r, g, b)) }
    }

    public let isDark: Bool
    /// Window ground (lime plaster / lapis night), panels (whitewash / night panel), words, quieter words, stone joints.
    public let background: RGB, card: RGB, text: RGB, muted: RGB, line: RGB
    /// Malachite: the one accent (Try again), pressed, the words on it, its soft wash, and its ink for small marks.
    public let accent: RGB, accentPressed: RGB, onAccent: RGB, softAccent: RGB, accentText: RGB
    /// Gold leaf: only ever a hairline, at `goldLineAlpha`. Never words, fills or buttons; never on a cover.
    public let gold: RGB, goldLineAlpha: CGFloat
    /// Covers: one calm neutral, never the accent, never gold.
    public let cover: RGB
    /// Key caps on the way-out line: plain neutral caps (face, rim, the deeper edge below) with near-black or
    /// near-white letters, so the keys are the most legible thing on a cover.
    public let keyFill: RGB, keyEdge: RGB, keyBase: RGB, keyText: RGB
    /// The way-out line's and the panels' soft shadow.
    public let shadowAlpha: CGFloat

    public static let light = CoverTheme(
        isDark: false,
        background: RGB(0xEFF1EC), card: RGB(0xFBFBF8), text: RGB(0x151C1B), muted: RGB(0x45504D), line: RGB(0xD8DCD3),
        accent: RGB(0x0B7363), accentPressed: RGB(0x085E51), onAccent: RGB(0xFFFFFF), softAccent: RGB(0xE0EDE7), accentText: RGB(0x06594D),
        gold: RGB(0xA68338), goldLineAlpha: 0.5,
        cover: RGB(0xE5E7E1),
        keyFill: RGB(0xF2F3EF), keyEdge: RGB(0xCDD2CA), keyBase: RGB(0xB9BFB6), keyText: RGB(0x151C1B),
        shadowAlpha: 0.10)

    public static let dark = CoverTheme(
        isDark: true,
        background: RGB(0x0C1222), card: RGB(0x131A2D), text: RGB(0xECEEE6), muted: RGB(0xA9B1BF), line: RGB(0x252E46),
        accent: RGB(0x5CD3BC), accentPressed: RGB(0x49C2AA), onAccent: RGB(0x071D19), softAccent: RGB(0x13303A), accentText: RGB(0x6FD9C4),
        gold: RGB(0xC9A961), goldLineAlpha: 0.36,
        cover: RGB(0x121828),
        keyFill: RGB(0x252E47), keyEdge: RGB(0x3A4562), keyBase: RGB(0x2E3853), keyText: RGB(0xF1F2EC),
        shadowAlpha: 0.45)

    /// The theme for an appearance: dark for any dark appearance, light otherwise.
    public static func forAppearance(_ a: NSAppearance?) -> CoverTheme {
        a?.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]).map { $0 == .aqua ? light : dark } ?? light
    }

    /// The theme for the system's current appearance.
    @MainActor public static var current: CoverTheme { forAppearance(NSApp?.effectiveAppearance) }

    /// A colour of the theme that follows the appearance it is drawn in, for windows that stay open while the
    /// appearance changes.
    public static func dynamic(_ key: KeyPath<CoverTheme, RGB>, alpha: CGFloat = 1) -> NSColor {
        let l = light[keyPath: key].ns(alpha), d = dark[keyPath: key].ns(alpha)
        return NSColor(name: nil) { forAppearance($0).isDark ? d : l }
    }

    // MARK: Type

    /// Headings: the system serif (New York), semibold. Covers and the way-out line never use it.
    public static func heading(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let sans = NSFont.systemFont(ofSize: size, weight: weight)
        return sans.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? sans
    }

    /// Serifs need less tightening than the sans: a little negative tracking, in points, for a heading of `size`.
    public static func headingKern(_ size: CGFloat) -> CGFloat { -0.008 * size }

    /// Body words: the system sans.
    public static func body(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
}
