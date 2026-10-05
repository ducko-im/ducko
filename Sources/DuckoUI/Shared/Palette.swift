import AppKit
import SwiftUI

enum Palette {
    static let accent = Color(light: 0x5B9BD5, dark: 0x4A8BC2)
    static let separator = Color(light: 0xE0E0E0, dark: 0x3A3A3A)
    static let outgoingBubble = accent
    private static let incomingBubble = Color(light: 0xE5E5EA, dark: 0x38383A)
    private static let outgoingBubbleText = Color.white
    private static let incomingBubbleText = Color(light: 0x000000, dark: 0xFFFFFF)

    static func bubble(isOutgoing: Bool) -> Color {
        isOutgoing ? outgoingBubble : incomingBubble
    }

    static func bubbleText(isOutgoing: Bool) -> Color {
        isOutgoing ? outgoingBubbleText : incomingBubbleText
    }
}

private extension Color {
    /// A color that follows the appearance it is drawn in, from `0xRRGGBB` values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
