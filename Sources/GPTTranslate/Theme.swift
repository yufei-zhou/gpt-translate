import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Claude-inspired palette: warm ivory paper, slate ink, terracotta accent.
@MainActor
enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let background = dynamic(NSColor(hex: 0xFAF9F5), NSColor(hex: 0x262624))
    static let sourceBackground = dynamic(NSColor(hex: 0xF3F1EA), NSColor(hex: 0x1F1E1D))
    static let text = dynamic(NSColor(hex: 0x141413), NSColor(hex: 0xF0EEE6))
    static let secondaryText = dynamic(NSColor(hex: 0x6F6E69), NSColor(hex: 0xA8A59D))
    static let tertiaryText = dynamic(NSColor(hex: 0xA6A49C), NSColor(hex: 0x6E6C66))
    static let border = dynamic(NSColor(hex: 0xE6E3D9), NSColor(hex: 0x3A3934))
    static let accent = NSColor(hex: 0xD97757)
    static let accentPressed = NSColor(hex: 0xC6613F)
    static let highlight = dynamic(NSColor(hex: 0xD97757, alpha: 0.20), NSColor(hex: 0xD97757, alpha: 0.32))
    static let selection = dynamic(NSColor(hex: 0xD97757, alpha: 0.30), NSColor(hex: 0xD97757, alpha: 0.42))

    static func contentFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let size = size ?? CGFloat(AppSettings.shared.fontSize)
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor
        if AppSettings.shared.serif, let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        // Keep CJK glyphs in PingFang rather than whatever fallback the serif face picks.
        descriptor = descriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(name: "PingFang SC", size: size)]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func textAttributes(color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.22
        paragraph.paragraphSpacing = 5
        return [.font: contentFont(), .foregroundColor: color ?? text, .paragraphStyle: paragraph]
    }
}

extension Color {
    @MainActor static let claudeAccent = Color(nsColor: Theme.accent)
    @MainActor static let claudeText = Color(nsColor: Theme.text)
    @MainActor static let claudeSecondary = Color(nsColor: Theme.secondaryText)
    @MainActor static let claudeTertiary = Color(nsColor: Theme.tertiaryText)
    @MainActor static let claudeBorder = Color(nsColor: Theme.border)
    @MainActor static let claudeBackground = Color(nsColor: Theme.background)
    @MainActor static let claudeSourceBackground = Color(nsColor: Theme.sourceBackground)
}
