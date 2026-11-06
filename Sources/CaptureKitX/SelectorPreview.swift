import Foundation
import AppKit
import CoreGraphics

/// 把区域选择器遮罩渲染成 PNG。用于没有屏幕录制权限时的 UI 自检与截图取证
/// （渲染的是同一份 SelectorView 绘制代码，不是另画一张示意图）。
public enum SelectorPreview {

    @MainActor
    public static func renderPNG(size: CGSize,
                                 selection: CGRect,
                                 mouse: CGPoint? = nil,
                                 pixelScale: CGFloat = 2,
                                 renderScale: CGFloat = 2,
                                 to url: URL) throws {
        _ = NSApplication.shared

        let view = SelectorView(frame: CGRect(origin: .zero, size: size))
        view.pixelScale = pixelScale
        view.configureForPreview(selection: selection, mouse: mouse)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * renderScale),
                                         pixelsHigh: Int(size.height * renderScale),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw AppErrorForPreview.renderFailed
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: renderScale, y: renderScale)
        // displayIgnoringOpacity 会按视图的 isFlipped 自行处理坐标系，
        // 手写 CTM 翻转会把文字画倒（已验证），所以交给 AppKit。
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw AppErrorForPreview.renderFailed
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    enum AppErrorForPreview: Error {
        case renderFailed
    }
}
