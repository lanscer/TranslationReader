import Foundation
import AppKit
import CoreGraphics
import Contracts

// MARK: - 模块级硬规定（2026-10-30 线上 SIGSEGV 之后固化，勿删）
//
// 本模块内**每一个自建的 NSWindow / NSPanel 都必须显式设置 isReleasedWhenClosed = false**。
// 原因：NSWindow(contentRect:styleMask:backing:defer:) 的 isReleasedWhenClosed 默认是 true，
// close() 会额外发一次 -release；只要 Swift 侧还有强引用（数组/属性）持着同一个窗口，就是过释放。
// 过释放不会当场崩，坏内存直到主 runloop 排空自动释放池才爆，栈形如
// objc_release → AutoreleasePoolPage::releaseUntil → -[NSApplication run]，极难反查。
// 同类回归用例：Tests/IntegrationTests/RegionSelectorRegressionTests.swift（20 次打开/关闭循环）。
// AppShell 侧自建窗口同规则（integration 同步自查）。
// 当前自建窗口清单（新增窗口请补进来）：ScreenCaptureService.present() 每屏一个遮罩窗（已显式关闭该属性）。

/// 屏幕截图与区域选择（文档 §6.3 / §5.3 截图路径）。
/// 实现在 ScreenRegionSelector / ScreenCaptureService / SelectorPreview。
public enum CaptureKitX {
    public static let moduleName = "CaptureKitX"

    /// 历史记录/日志用的可持久化区域描述（T1 冻结的 DTO）。
    public struct CaptureRegion: Codable, Hashable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public init(_ rect: CGRect) {
            self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }

        public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// 一次区域选择的几何结果。
    /// rect 使用「显示器内点坐标、左上原点、Y 向下」，与 SCStreamConfiguration.sourceRect 语义一致。
    public struct RegionSelection: Sendable, Hashable {
        public let displayID: CGDirectDisplayID
        public let rect: CGRect
        /// 显示器物理像素 / 点。
        public let scale: CGFloat
        public let isFullScreen: Bool

        public init(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat, isFullScreen: Bool) {
            self.displayID = displayID
            self.rect = rect
            self.scale = scale
            self.isFullScreen = isFullScreen
        }

        public var pixelSize: CGSize {
            CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        }

        public var captureRegion: CaptureRegion { CaptureRegion(rect) }
    }

    /// 截图结果：像素尺寸与点尺寸分开报，便于核对 Retina 换算。
    public struct CapturedImage: Sendable {
        public let image: CGImage
        public let pixelSize: CGSize
        public let pointSize: CGSize

        public init(image: CGImage, pixelSize: CGSize, pointSize: CGSize) {
            self.image = image
            self.pixelSize = pixelSize
            self.pointSize = pointSize
        }

        public var scale: CGFloat { pointSize.width > 0 ? pixelSize.width / pointSize.width : 1 }
    }

    /// 选择 + 截图的一次完整结果（⌥S 主链路用这个）。
    public struct CaptureOutcome: Sendable {
        public let selection: RegionSelection
        public let captured: CapturedImage

        public init(selection: RegionSelection, captured: CapturedImage) {
            self.selection = selection
            self.captured = captured
        }
    }

    /// 缺少屏幕录制权限时统一抛 Contracts.AppError（文档 §7：不静默失败）。
    public static func permissionError() -> AppError {
        .permissionDenied(kind: .screenRecording)
    }

    /// 「权限没问题，但当前截不到」：preflight 通过而 ScreenCaptureKit 拿不到显示器列表。
    /// 实测成因是显示器休眠 / 锁屏 / 截屏服务未就绪（caffeinate 唤醒后同一个探针立刻返回 displays=[1]）。
    /// 不能报 permissionDenied —— 那会把人骗去系统设置（2026-10-30 用户实测踩到）。
    public static func displayUnavailableError() -> AppError {
        .unknown(message: "屏幕当前不可截取：显示器可能已休眠或锁屏，唤醒后重试；若持续失败请检查屏幕录制权限与显示器连接。")
    }
}
