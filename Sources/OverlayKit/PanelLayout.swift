import CoreGraphics

/// 浮条/弹窗的最终落位。flipped* 用于日志与验收取证。
public struct PanelPlacement: Equatable, Sendable {
    public let frame: CGRect
    public let flippedHorizontally: Bool
    public let flippedVertically: Bool

    public init(frame: CGRect, flippedHorizontally: Bool = false, flippedVertically: Bool = false) {
        self.frame = frame
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
    }
}

/// 文档 §3.1 / §6.2 的定位规则：选区包围盒右上角 +8pt；贴边自动翻转；多屏取包含选区的屏。
/// 纯函数，单测直接覆盖（坐标全用 AppKit 左下原点）。
public enum OverlayLayout {
    public static let edgeInset: CGFloat = 4

    /// 浮条落位。
    /// - Parameters:
    ///   - selection: 选区包围盒（AppKit 屏幕坐标）
    ///   - size: 浮条自身尺寸
    ///   - screenVisibleFrame: 目标屏的 visibleFrame（已扣掉菜单栏与 Dock）
    ///   - offset: 与选区的间距，文档定的是 8pt
    public static func barPlacement(
        selection: CGRect,
        size: CGSize,
        screenVisibleFrame: CGRect,
        offset: CGFloat = 8,
        inset: CGFloat = edgeInset
    ) -> PanelPlacement {
        var origin = CGPoint(x: selection.maxX + offset, y: selection.maxY + offset)
        var flippedHorizontally = false
        var flippedVertically = false

        if origin.x + size.width > screenVisibleFrame.maxX - inset {
            origin.x = selection.minX - offset - size.width
            flippedHorizontally = true
        }
        if origin.y + size.height > screenVisibleFrame.maxY - inset {
            origin.y = selection.minY - offset - size.height
            flippedVertically = true
        }

        origin.x = clamp(origin.x, lower: screenVisibleFrame.minX + inset, upper: screenVisibleFrame.maxX - inset - size.width)
        origin.y = clamp(origin.y, lower: screenVisibleFrame.minY + inset, upper: screenVisibleFrame.maxY - inset - size.height)
        return PanelPlacement(
            frame: CGRect(origin: origin, size: size),
            flippedHorizontally: flippedHorizontally,
            flippedVertically: flippedVertically
        )
    }

    /// 翻译卡落位：优先选区右侧、垂直居中；右侧放不下放到左侧；两侧都放不下放到选区下方。
    public static func cardPlacement(
        selection: CGRect,
        size: CGSize,
        screenVisibleFrame: CGRect,
        gap: CGFloat = 12,
        inset: CGFloat = 8
    ) -> PanelPlacement {
        var origin = CGPoint(x: selection.maxX + gap, y: selection.midY - size.height / 2)
        var flippedHorizontally = false

        if origin.x + size.width > screenVisibleFrame.maxX - inset {
            origin.x = selection.minX - gap - size.width
            flippedHorizontally = true
        }
        if origin.x < screenVisibleFrame.minX + inset {
            origin.x = selection.midX - size.width / 2
            origin.y = selection.minY - gap - size.height
            flippedHorizontally = false
        }

        origin.x = clamp(origin.x, lower: screenVisibleFrame.minX + inset, upper: screenVisibleFrame.maxX - inset - size.width)
        origin.y = clamp(origin.y, lower: screenVisibleFrame.minY + inset, upper: screenVisibleFrame.maxY - inset - size.height)
        return PanelPlacement(frame: CGRect(origin: origin, size: size), flippedHorizontally: flippedHorizontally, flippedVertically: false)
    }

    /// 文档 §6.2：遍历 NSScreen.screens 选包含选区的屏。
    /// 命中规则：① 选区中点所在屏；② 相交面积最大的屏；③ 中心距离最近的屏。
    public static func screenIndex(containing selection: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: selection.midX, y: selection.midY)
        if let index = screens.firstIndex(where: { $0.contains(center) }) {
            return index
        }

        let intersections = screens.map { $0.intersection(selection) }
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, rect) in intersections.enumerated() where !rect.isNull {
            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        if let bestIndex { return bestIndex }

        var nearestIndex: Int?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (index, rect) in screens.enumerated() {
            let dx = rect.midX - center.x
            let dy = rect.midY - center.y
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        return nearestIndex
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }
}
