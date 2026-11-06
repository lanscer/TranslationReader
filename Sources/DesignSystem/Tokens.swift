import SwiftUI
import AppKit
import Contracts

// 文档 §4.1 / §4.2 的视觉 token。DesignSystem 不依赖任何业务模块，只依赖 Contracts。
public enum DSColor {
    public static let surface = dynamic(light: 0xF8F8F8, dark: 0x282828)
    public static let surfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x404048)
    public static let surfaceSunken = dynamic(light: 0xF0F0F0, dark: 0x1F1F1F)
    public static let textPrimary = dynamic(light: 0x1A1A1A, dark: 0xF2F2F2)
    public static let textSecondary = dynamic(light: 0x666666, dark: 0xA8A8B0)
    public static let accent = dynamic(light: 0x2F6BFF, dark: 0x5B8CFF)
    public static let divider = dynamic(light: 0xE0E0E0, dark: 0x3A3A40)
    public static let danger = dynamic(light: 0xD93B3B, dark: 0xFF6B6B)

    // MARK: - 翻译卡专用（千问式深色；浅色主题也有一套，见文档 §4.1）
    /// 卡片底：浅色近白，深色取千问的 #282828 一档。
    public static let cardSurface = dynamic(light: 0xF7F7F8, dark: 0x282828)
    /// 卡片内抬升块（输入条、tab 选中）。
    public static let cardSurfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x404048)
    public static let cardTextPrimary = dynamic(light: 0x1A1A1A, dark: 0xF2F2F2)
    public static let cardTextSecondary = dynamic(light: 0x666666, dark: 0xA8A8B0)
    /// 词条蓝（有道式词条标题 + 播放中高亮）。
    public static let cardAccent = dynamic(light: 0x2F6BFF, dark: 0x6E9BFF)
    public static let cardDivider = dynamic(light: 0xE4E4E6, dark: 0x3E3E46)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let ns = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
        return Color(nsColor: ns)
    }
}

public enum DSMetric {
    public static let cardCorner: CGFloat = 12
    public static let barCorner: CGFloat = 10
    public static let buttonCorner: CGFloat = 8
    public static let barShadowY: CGFloat = 2
    public static let barShadowBlur: CGFloat = 12
    public static let barShadowAlpha: Double = 0.18
    public static let cardWidth: CGFloat = 420
    public static let cardMaxHeight: CGFloat = 560
    public static let selectionBarOffset: CGFloat = 8
}

public enum DSFont {
    public static let sourceText = Font.system(size: 16)
    public static let translation = Font.system(size: 17, weight: .medium)
    public static let lemmaTitle = Font.system(size: 17, weight: .semibold)
    public static let posTag = Font.system(size: 12).italic()
    public static let senseIndex = Font.system(size: 12)
    public static let speakButton = Font.system(size: 16)
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
