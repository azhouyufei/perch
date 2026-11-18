import AppKit

/// Shared by SwiftUI surfaces and the web island. Appearance is resolved by AppKit,
/// so an explicit app preference and a change to the system theme use the same path.
public struct PerchPalette {
    public enum Token: String, CaseIterable {
        case start, middle, end, card, raised, ink, muted, inverse
    }
    public let dark: Bool
    public init(dark: Bool) { self.dark = dark }
    public init(appearance: NSAppearance) {
        dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    public func rgb(_ token: Token) -> UInt32 {
        switch token {
        case .start: return dark ? 0x211F30 : 0xF5F3FB
        case .middle: return dark ? 0x151C29 : 0xF1F5FA
        case .end: return dark ? 0x10141C : 0xEAEFF8
        case .card: return dark ? 0x232836 : 0xFFFFFF
        case .raised: return dark ? 0x343A4B : 0xE0E4EF
        case .ink: return dark ? 0xF4F5FC : 0x202432
        case .muted: return dark ? 0xABB2C5 : 0x5B6478
        case .inverse: return dark ? 0x202432 : 0xF4F5FC
        }
    }
    public func color(_ token: Token) -> NSColor {
        let value = rgb(token)
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    public var cssVariables: [String: String] {
        var values = [String: String]()
        for token in Token.allCases {
            let v = rgb(token)
            values["--perch-\(token.rawValue)"] = String(format: "#%06X", v)
            values["--perch-\(token.rawValue)-rgb"] = "\((v >> 16) & 255),\((v >> 8) & 255),\(v & 255)"
            // Tailwind's existing opacity utilities consume HSL components.
            let c = color(token).usingColorSpace(.sRGB)!
            let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
            let hi = max(r, g, b), lo = min(r, g, b), delta = hi - lo, l = (hi + lo) / 2
            var h = 0.0
            if delta > 0 {
                if hi == r { h = (g - b) / delta + (g < b ? 6 : 0) }
                else if hi == g { h = (b - r) / delta + 2 }
                else { h = (r - g) / delta + 4 }
            }
            let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
            values["--perch-\(token.rawValue)-hsl"] = String(format: "%.2f %.2f%% %.2f%%", locale: Locale(identifier: "en_US_POSIX"), h * 60, saturation * 100, l * 100)
        }
        return values
    }
}
