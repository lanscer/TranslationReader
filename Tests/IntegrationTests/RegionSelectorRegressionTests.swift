import Testing
import AppKit
import CoreGraphics
import Contracts
import CaptureKitX

/// 区域选择器生命周期回归（2026-10-30 线上 SIGSEGV 的防复发用例）。
///
/// 崩溃形态：遮罩窗未设 isReleasedWhenClosed=false → close() 额外 release，与强引用数组叠加即过释放，
/// 崩溃延后到主 runloop 排空自动释放池（objc_release in AutoreleasePoolPage::releaseUntil）。
///
/// 双模行为（重要）：TCC 按二进制身份授权，且「显示器休眠/锁屏」也会让 ScreenCaptureKit 返回空显示器列表，
/// 两种情况下都不能让 make test 变红。判据用**首轮实际结果**（CGPreflightScreenCaptureAccess 会 true 但 displays 为空）：
///  · captured:WxH                     → 有权限且屏在线：后续每轮必须 captured:WxH 且非 0x0；
///  · permissionDenied                 → 真没授权：后续每轮必须 permissionDenied；
///  · unknown(含「唤醒」「重试」)         → 屏休眠/截屏服务未就绪：后续每轮必须同款可操作文案。
/// 三种模式都保留「遮罩窗零残留」断言，保证窗口生命周期在任何机器上都被验到。
///
/// 说明：本用例会真实创建全屏遮罩窗，每轮几十毫秒后立刻关闭，跑测试时屏幕会短暂变暗。
/// 拖框用进程内 NSEvent + window.sendEvent，不 post 到系统，不移动用户光标、不点击真实 UI。
@Suite("区域选择器生命周期回归", .serialized)
@MainActor
struct RegionSelectorRegressionTests {

    static let iterations = 20

    enum CaptureMode {
        case capture            // 有权限 + 屏在线
        case noPermission       // 无屏幕录制权限
        case displayUnavailable // 屏休眠/锁屏/截屏服务未就绪
    }

    @Test("连续 20 次 selectRegion()：每次正常取消、窗口全部释放")
    func cancelLoop() async {
        _ = NSApplication.shared
        for index in 0..<Self.iterations {
            let selector = ScreenRegionSelector()
            let task = Task { @MainActor () -> String in
                do {
                    _ = try await selector.selectRegion()
                    return "unexpected-success"
                } catch {
                    return "\(error)"
                }
            }
            await Self.spin { !Self.overlayWindows.isEmpty }
            #expect(!Self.overlayWindows.isEmpty, "第 \(index + 1) 次未出现遮罩窗")
            selector.cancel()
            let outcome = await task.value
            #expect(outcome.contains("cancelled"), "第 \(index + 1) 次返回值异常：\(outcome)")
            #expect(Self.overlayWindows.isEmpty, "第 \(index + 1) 次结束后仍残留遮罩窗（疑似窗口泄漏）")
        }
    }

    @Test("连续 20 次 selectAndCapture()：每次正常返回、窗口全部释放（三模断言）")
    func captureLoop() async {
        _ = NSApplication.shared
        var mode: CaptureMode?
        for index in 0..<Self.iterations {
            let selector = ScreenRegionSelector()
            let task = Task { @MainActor () -> String in
                do {
                    let outcome = try await selector.selectAndCapture(settleMilliseconds: 0)
                    return "captured:\(Int(outcome.captured.pixelSize.width))x\(Int(outcome.captured.pixelSize.height))"
                } catch {
                    return "\(error)"
                }
            }
            await Self.spin { !Self.overlayWindows.isEmpty }
            #expect(!Self.overlayWindows.isEmpty, "第 \(index + 1) 次未出现遮罩窗")
            Self.dragInOverlay()
            let outcome = await task.value
            if mode == nil {
                mode = Self.mode(for: outcome)
                print("[region-selector] capture mode = \(Self.describe(mode!) ), 首轮结果：\(outcome)")
            }
            switch mode {
            case .capture:
                #expect(outcome.hasPrefix("captured:"), "第 \(index + 1) 次未截图成功：\(outcome)")
                #expect(outcome != "captured:0x0", "第 \(index + 1) 次截图为空")
            case .noPermission:
                #expect(outcome.contains("permissionDenied"),
                        "第 \(index + 1) 次无权限时应抛 permissionDenied，实际：\(outcome)")
            case .displayUnavailable:
                Self.expectActionableDisplayMessage(outcome, index: index)
            case .none:
                break
            }
            #expect(Self.overlayWindows.isEmpty, "第 \(index + 1) 次结束后仍残留遮罩窗（疑似窗口泄漏）")
        }
    }

    // MARK: - 辅助

    static func mode(for outcome: String) -> CaptureMode {
        if outcome.hasPrefix("captured:") { return .capture }
        if outcome.contains("permissionDenied") { return .noPermission }
        return .displayUnavailable
    }

    static func describe(_ mode: CaptureMode) -> String {
        switch mode {
        case .capture: return "真实截图"
        case .noPermission: return "无屏幕录制权限，走权限断言"
        case .displayUnavailable: return "显示器休眠/截屏服务未就绪，走可操作文案断言"
        }
    }

    /// 休眠分支不允许退化成「干巴巴的 unknown」：文案必须同时含「唤醒」与「重试」。
    static func expectActionableDisplayMessage(_ outcome: String, index: Int) {
        #expect(outcome.contains("唤醒"), "第 \(index + 1) 次休眠文案缺少「唤醒」：\(outcome)")
        #expect(outcome.contains("重试"), "第 \(index + 1) 次休眠文案缺少「重试」：\(outcome)")
        #expect(!outcome.contains("permissionDenied"),
                "第 \(index + 1) 次把「显示器不可截取」误报成权限问题：\(outcome)")
    }

    /// 遮罩层级的窗口（selector 自己创建的），用层级筛掉测试进程里的其它窗口。
    static var overlayWindows: [NSWindow] {
        NSApp.windows.filter { $0.level == .screenSaver }
    }

    /// 主 runloop 上推进，直到条件成立或超时（present 需要一次 runloop 周期）。
    static func spin(until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            await Task.yield()
        }
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// 进程内合成一次拖框：mouseDown → mouseDragged → mouseUp。
    static func dragInOverlay() {
        guard let window = overlayWindows.first else {
            Issue.record("拖框时找不到遮罩窗")
            return
        }
        let height = window.frame.height
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ yFromTop: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type,
                               location: NSPoint(x: x, y: height - yFromTop),
                               modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber,
                               context: nil,
                               eventNumber: 0,
                               clickCount: 1,
                               pressure: 1)
        }
        if let down = event(.leftMouseDown, 120, 120) { window.sendEvent(down) }
        if let drag = event(.leftMouseDragged, 620, 420) { window.sendEvent(drag) }
        if let up = event(.leftMouseUp, 620, 420) { window.sendEvent(up) }
    }
}

/// 截图前置条件 → 错误映射（2026-10-30 裁定：权限与「显示器不可截取」必须分流）。
@Suite("截图前置条件错误映射")
struct CapturePreconditionTests {

    @Test("无屏幕录制权限 → permissionDenied（可引导授权）")
    func noPermission() {
        let error = ScreenCaptureService.capturePreconditionError(hasPermission: false,
                                                                  availableDisplayIDs: [1],
                                                                  targetDisplayID: 1)
        #expect(error == .permissionDenied(kind: .screenRecording))
        #expect(error?.requiresPermissionGuide == true)
        #expect(error?.userMessage.contains("屏幕录制") == true)
    }

    @Test("有权限但显示器列表为空 → unknown，且文案含「唤醒」「重试」，不得报成权限问题")
    func emptyDisplayList() {
        let error = ScreenCaptureService.capturePreconditionError(hasPermission: true,
                                                                  availableDisplayIDs: [],
                                                                  targetDisplayID: 1)
        guard case .unknown(let message) = error else {
            Issue.record("空显示器列表应报 unknown(可操作文案)，实际：\(String(describing: error))")
            return
        }
        #expect(message.contains("唤醒"))
        #expect(message.contains("重试"))
        #expect(error?.requiresPermissionGuide == false, "休眠不该弹授权引导卡")
    }

    @Test("有权限但目标 displayID 不在列表 → 同样走显示器不可截取文案")
    func missingTargetDisplay() {
        let error = ScreenCaptureService.capturePreconditionError(hasPermission: true,
                                                                  availableDisplayIDs: [1, 2],
                                                                  targetDisplayID: 3)
        guard case .unknown(let message) = error else {
            Issue.record("目标屏缺失应报 unknown(可操作文案)，实际：\(String(describing: error))")
            return
        }
        #expect(message.contains("唤醒"))
        #expect(message.contains("重试"))
    }

    @Test("权限与显示器齐备 → 无错误")
    func allGood() {
        #expect(ScreenCaptureService.capturePreconditionError(hasPermission: true,
                                                              availableDisplayIDs: [1],
                                                              targetDisplayID: 1) == nil)
    }

    @Test("CaptureLog 可被 AppShell 接上统一日志，并带上 capture-precondition 现场字段")
    func logSink() {
        var lines: [String] = []
        let previous = CaptureLog.sink
        CaptureLog.sink = { lines.append($0) }
        defer { CaptureLog.sink = previous }
        CaptureLog.ax("capture-precondition preflight=true displays=[] target=1 → displayUnavailable（休眠/锁屏/截屏服务未就绪）")
        #expect(lines.count == 1)
        #expect(lines.first?.contains("capture-precondition") == true)
        #expect(lines.first?.contains("displays=[]") == true)
    }
}