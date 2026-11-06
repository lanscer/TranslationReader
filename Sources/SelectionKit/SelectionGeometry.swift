import CoreGraphics

/// 文档 §6.1：AX 全局坐标（主屏左上原点、y 向下）与 AppKit 屏幕坐标（主屏左下原点、y 向上）的换算。
/// 纯函数，单测直接覆盖。
public enum AXGeometry {
    /// AX → AppKit。
    /// - Parameters:
    ///   - rect: AX 返回的包围盒（左上原点，y 向下）
    ///   - primaryScreenHeight: 主屏高度，即 NSScreen.screens[0].frame.maxY
    public static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        guard !rect.isNull, !rect.isInfinite else { return .zero }
        return CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// AppKit → AX。纵向翻转是对合运算，公式与反方向完全一致。
    public static func axRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        appKitRect(fromAX: rect, primaryScreenHeight: primaryScreenHeight)
    }
}
