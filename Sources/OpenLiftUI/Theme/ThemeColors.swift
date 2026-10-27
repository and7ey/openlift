import AppKit
import OpenLiftCore

public extension ThemeAppearance {
    /// AppKit appearance for the theme, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

public extension Theme {
    var backgroundColor: NSColor? { Self.color(from: background) }
    var alternateBackgroundColor: NSColor? { Self.color(from: alternateBackground) }
    var selectionColor: NSColor? { Self.color(from: selection) }

    /// Parses `RRGGBB`; anything else falls back to the system color.
    static func color(from hex: String?) -> NSColor? {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
