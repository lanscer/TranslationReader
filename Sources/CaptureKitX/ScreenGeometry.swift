import Foundation
import AppKit
import CoreGraphics

/// 屏幕几何换算：NSScreen（左下原点）↔ CGDisplayBounds / SCK（左上原点）。
public enum ScreenGeometry {

    /// NSScreen 对应的 CGDirectDisplayID。
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// 物理像素 / 点（Retina 上为 2）。
    /// 注意：HiDPI 缩放模式下 CGDisplayPixelsWide 返回的是逻辑宽度（如 1728），
    /// 真实像素宽度要读 display mode 的 pixelWidth（如 3456），否则截图会退化成 1x。
    public static func pixelScale(of displayID: CGDirectDisplayID) -> CGFloat {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 else { return 2 }
        var pixels = CGFloat(CGDisplayPixelsWide(displayID))
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let modePixels = CGFloat(mode.pixelWidth)
            if modePixels > pixels { pixels = modePixels }
        }
        return pixels / bounds.width
    }

    /// 诊断用：把当前显示器的点/像素信息拼成一行人读文本。
    public static func describe(_ displayID: CGDirectDisplayID) -> String {
        let bounds = CGDisplayBounds(displayID)
        let modePixels = CGDisplayCopyDisplayMode(displayID)?.pixelWidth ?? -1
        let backing = NSScreen.screens.first { self.displayID(of: $0) == displayID }?.backingScaleFactor ?? -1
        return "display=\(displayID) bounds=\(Int(bounds.width))x\(Int(bounds.height))pt pixelsWide=\(CGDisplayPixelsWide(displayID)) modePixelWidth=\(modePixels) backingScale=\(backing) derivedScale=\(pixelScale(of: displayID))"
    }

    /// 把显示器内的点坐标（左上原点、Y 向下）钳制到显示器边界内。
    public static func clamp(_ rect: CGRect, to displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        let local = CGRect(origin: .zero, size: bounds.size)
        return rect.intersection(local).integral
    }
}
