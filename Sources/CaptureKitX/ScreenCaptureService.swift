import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import Contracts

/// 弱引用窗口盒子：截图期间保活判断用，避免向已释放窗口发消息。
private final class WeakWindow {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}

/// SCScreenshotManager 区域截图（macOS 14+）。权限缺失时抛 AppError.permissionDenied，不返回空图。
public enum ScreenCaptureService {

    /// CGPreflightScreenCaptureAccess 不弹系统授权框，可随时查询。
    public static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 只有用户主动点「授权」时才调用（会弹系统 TCC 对话框）。
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 截取选中区域。hiding 里的窗口（浮条/弹窗/遮罩）会在截图前 orderOut，截完恢复（文档 §6.3「屏蔽自身」）。
    /// settleMilliseconds：窗口隐藏后等待合成器刷新，避免把自身残影截进图里。
    @MainActor
    public static func capture(_ selection: CaptureKitX.RegionSelection,
                               hiding windows: [NSWindow] = [],
                               settleMilliseconds: UInt64 = 60) async throws -> CaptureKitX.CapturedImage {
        guard !selection.rect.isEmpty else {
            throw AppError.unknown(message: "选区为空，无法截图。")
        }
        // 弱引用持有：等待截图期间调用方可能已经把浮条/弹窗关掉并释放，
        // 直接 orderFront 一个已释放的 NSWindow 会踩野指针。
        let toHide = windows.filter { $0.isVisible }.map(WeakWindow.init)
        toHide.forEach { $0.window?.orderOut(nil) }
        do {
            if settleMilliseconds > 0 {
                try await Task.sleep(nanoseconds: settleMilliseconds * 1_000_000)
            }
            let image = try await captureCore(selection)
            toHide.forEach { $0.window?.orderFront(nil) }
            return image
        } catch {
            toHide.forEach { $0.window?.orderFront(nil) }
            throw error
        }
    }

    static func captureCore(_ selection: CaptureKitX.RegionSelection) async throws -> CaptureKitX.CapturedImage {
        guard hasScreenRecordingPermission else { throw CaptureKitX.permissionError() }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw mapError(error)
        }
        let displayIDs = content.displays.map { $0.displayID }
        let precondition = capturePreconditionError(hasPermission: hasScreenRecordingPermission,
                                                    availableDisplayIDs: displayIDs,
                                                    targetDisplayID: selection.displayID)
        // [ax] 级现场日志：用户报「截图没反应」时，从这一行就能区分是权限问题还是显示器休眠。
        CaptureLog.ax("capture-precondition preflight=\(hasScreenRecordingPermission) displays=\(displayIDs) target=\(selection.displayID) → \(Self.describe(precondition))")
        if let precondition { throw precondition }
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw CaptureKitX.permissionError()
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let rect = selection.rect
        let scale = selection.scale > 0 ? selection.scale : 1
        // 配置里的宽高是「像素」；sourceRect 是「点」，坐标原点在显示器左上角、Y 向下。
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.sourceRect = rect
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CaptureKitX.CapturedImage(image: image,
                                             pixelSize: CGSize(width: image.width, height: image.height),
                                             pointSize: rect.size)
        } catch {
            throw mapError(error)
        }
    }

    /// 截图前置条件判定（纯函数，单测直接验；captureCore 的唯一判据来源）。
    ///
    /// 为什么「拿不到显示器列表 / 找不到目标显示器」也报 permissionDenied：
    /// TCC 条目过期、应用被重签名、或测试进程从未授权时，SCShareableContent 往往**不抛 userDeclined**，
    /// 而是返回空列表或少了目标屏。此时按「显示器已断开」上报，用户没有任何可操作项；
    /// 按权限上报，UI 才会走 requiresPermissionGuide 的授权引导卡（文档 §7「不静默失败」）。
    public static func capturePreconditionError(hasPermission: Bool,
                                                availableDisplayIDs: [CGDirectDisplayID],
                                                targetDisplayID: CGDirectDisplayID) -> AppError? {
        if !hasPermission { return CaptureKitX.permissionError() }
        // 预检通过却拿不到显示器：这是「显示器休眠/锁屏/截屏服务未就绪」，与权限是两个故障面。
        // 报 permissionDenied 会把用户骗去系统设置（2026-10-30 实测：preflight=true、windows=23、displays=[]，
        // caffeinate -u 唤醒后立刻 displays=[1]）。
        if availableDisplayIDs.isEmpty { return CaptureKitX.displayUnavailableError() }
        if !availableDisplayIDs.contains(targetDisplayID) { return CaptureKitX.displayUnavailableError() }
        return nil
    }

    /// 日志用的结论短语。
    static func describe(_ error: AppError?) -> String {
        guard let error else { return "通过" }
        switch error {
        case .permissionDenied: return "permissionDenied（屏幕录制未授权）"
        case .unknown(let message) where message.contains("不可截取"): return "displayUnavailable（休眠/锁屏/截屏服务未就绪）"
        default: return "其他错误"
        }
    }

    static func mapError(_ error: Error) -> AppError {
        let nsError = error as NSError
        // -3801 = userDeclined（用户拒绝了屏幕录制授权）。
        // 另外：只要当前进程本来就无授权，任何 ScreenCaptureKit 失败都按权限问题上报，
        // 否则用户会看到「截图失败：xxx」这种无从下手的信息。
        if nsError.code == -3801 || !hasScreenRecordingPermission {
            return CaptureKitX.permissionError()
        }
        return AppError.unknown(message: "截图失败：\(nsError.localizedDescription)")
    }
}

/// 全屏遮罩区域选择器：每屏一个 borderless 透明窗（文档 §5.3 截图路径）。
@MainActor
public final class ScreenRegionSelector {

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    /// 诊断：最近一次「热键 → 遮罩可拖框」耗时（文档 §9 要求 ≤120ms）。
    public private(set) var lastPresentDurationMs: Int = 0
    private var continuation: CheckedContinuation<CaptureKitX.RegionSelection, Error>?
    private var finished = false

    public init() {}

    /// 唤起遮罩并等待拖框。Esc/无选区取消 → AppError.cancelled。
    public func selectRegion() async throws -> CaptureKitX.RegionSelection {
        guard continuation == nil else { throw AppError.unknown(message: "区域选择器已在运行。") }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CaptureKitX.RegionSelection, Error>) in
            self.continuation = continuation
            self.present()
        }
    }

    /// ⌥S 主链路：选区域 → 隐藏自身窗口 → 截图 → 恢复。
    public func selectAndCapture(hiding hidden: [NSWindow] = [],
                                 settleMilliseconds: UInt64 = 60) async throws -> CaptureKitX.CaptureOutcome {
        let selection = try await selectRegion()
        let captured = try await ScreenCaptureService.capture(selection,
                                                              hiding: hidden,
                                                              settleMilliseconds: settleMilliseconds)
        return CaptureKitX.CaptureOutcome(selection: selection, captured: captured)
    }

    public func cancel() {
        finish(with: .failure(AppError.cancelled))
    }

    // MARK: - 展示与拆除

    private func present() {
        let started = DispatchTime.now()
        finished = false
        for screen in NSScreen.screens {
            guard let displayID = ScreenGeometry.displayID(of: screen) else { continue }
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: .borderless,
                                  backing: .buffered,
                                  defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            // 关键：ARC 下必须关掉 isReleasedWhenClosed。NSWindow 的默认值是 true，
            // close() 会额外发一次 -release，与 Swift 强引用（windows 数组）叠加即过释放，
            // 崩溃延后到主 runloop 排空自动释放池时（线上 SIGSEGV 的根因）。
            window.isReleasedWhenClosed = false

            let view = SelectorView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.pixelScale = ScreenGeometry.pixelScale(of: displayID)
            let scale = view.pixelScale
            let screenFrame = screen.frame
            view.onFinish = { [weak self] rect in
                self?.finish(with: .success(CaptureKitX.RegionSelection(displayID: displayID,
                                                                        rect: rect,
                                                                        scale: scale,
                                                                        isFullScreen: false)))
            }
            view.onFullScreen = { [weak self] in
                self?.finish(with: .success(CaptureKitX.RegionSelection(displayID: displayID,
                                                                        rect: CGRect(origin: .zero, size: screenFrame.size),
                                                                        scale: scale,
                                                                        isFullScreen: true)))
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
        }

        // borderless 窗默认可成为 key 才能收到 keyDown；app 是 accessory，需要主动激活一次热键触发。
        NSApp.activate(ignoringOtherApps: true)
        if let first = windows.first {
            first.makeKey()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: self?.cancel(); return nil
            case 49:
                self?.finishFullScreenForScreenUnderMouse()
                return nil
            default: return event
            }
        }
        lastPresentDurationMs = Int(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
    }

    private func finishFullScreenForScreenUnderMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen, let displayID = ScreenGeometry.displayID(of: screen) else { return }
        finish(with: .success(CaptureKitX.RegionSelection(displayID: displayID,
                                                          rect: CGRect(origin: .zero, size: screen.frame.size),
                                                          scale: ScreenGeometry.pixelScale(of: displayID),
                                                          isFullScreen: true)))
    }

    private func finish(with result: Result<CaptureKitX.RegionSelection, Error>) {
        guard !finished else { return }
        finished = true

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        // 先清空强引用数组再让 window 自然释放；isReleasedWhenClosed=false 保证 close() 不额外 release。
        windows.removeAll()

        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let selection): continuation?.resume(returning: selection)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
