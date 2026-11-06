import AppKit
import Contracts
import CaptureKitX
import OCRVision

/// ⌥S 截图链路：遮罩拖框 → ScreenCaptureKit → Vision OCR → 可编辑确认态 → 翻译 + 朗读（文档 §5.3）。
@MainActor
final class CaptureFlow {
    private unowned let env: AppEnvironment
    /// 强引用保活：遮罩窗 / 截图 / OCR 结果在流程结束前都不释放，避免 pool drain 时 over-release。
    private var selector: ScreenRegionSelector?
    private var retainedWindows: [NSWindow] = []
    private var retainedImage: CGImage?
    private var isRunning = false
    /// 本次流程开始时间：热键重入与看门狗都用它判断「是否卡死」。
    private var startedAt: Date?
    private var watchdog: Task<Void, Never>?
    private(set) var lastPresentDurationMs: Int?
    private(set) var lastOCRMs: Int?

    init(env: AppEnvironment) {
        self.env = env
    }

    func run() {
        if isRunning {
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            // 卡死自救：OCR 曾出现 Vision 长时间不返回、整条链路停在「截图完成」之后。
            // 超过 30s 视为卡死，先强制复位再重新开始，避免用户必须重启 App。
            guard elapsed > 40 else {
                AppLog.echo(String(format: "截图流程已在运行（%.0fs），忽略重复触发", elapsed), AppLog.ax)
                return
            }
            AppLog.echo(String(format: "截图流程已卡住 %.0fs，强制复位后重新开始", elapsed), AppLog.ax)
            finishUp()
        }
        // 同步创建/销毁窗口的一段包在 autoreleasepool 里（崩溃报告指向 pool drain 时的 over-release）。
        autoreleasepool {
            start()
        }
    }

    private func start() {
        guard PermissionCenter.screenRecordingGranted else {
            env.toast.show("缺少「屏幕录制」权限：⌥S 需要它才能截图", isError: true, seconds: 3.6)
            env.permissions.show()
            env.permissions.openSettings(.screenRecording)
            return
        }
        let selector = ScreenRegionSelector()
        self.selector = selector
        isRunning = true
        startedAt = Date()
        startWatchdog()
        Task { @MainActor in
            defer { self.finishUp() }
            do {
                let outcome = try await selector.selectAndCapture()
                self.lastPresentDurationMs = selector.lastPresentDurationMs
                AppLog.echo("截图完成 display=\(outcome.selection.displayID) 像素=\(Int(outcome.captured.pixelSize.width))x\(Int(outcome.captured.pixelSize.height)) 遮罩耗时=\(selector.lastPresentDurationMs)ms", AppLog.ax)
                // 截图结果显式保活到 OCR 结束（CGImage 不受 ARC 管理，防止提前回收）。
                self.retainedImage = outcome.captured.image
                let ocrStarted = DispatchTime.now()
                // 冷启动（预热还没跑完）时模型加载约 30s，放宽到 45s 并给用户一句提示；
                // 预热完成后单次识别 0.4–1s，12s 足够。超时兜底保证链路不会永久挂起。
                let cold = !OCRVision.isPrewarmed
                if cold {
                    self.env.toast.show("首次文字识别要加载模型，最多等 45 秒…", seconds: 3)
                    AppLog.echo("OCR 冷启动：预热尚未完成，使用 45s 超时", AppLog.ax)
                }
                let result = try await OCRVision.recognizeWithTimeout(
                    image: outcome.captured.image,
                    timeout: cold ? 45 : 12
                )
                self.lastOCRMs = Int((DispatchTime.now().uptimeNanoseconds - ocrStarted.uptimeNanoseconds) / 1_000_000)
                let text = result.lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                AppLog.echo("OCR 完成 行数=\(result.lines.count) 耗时=\(result.elapsedMs)ms(内部)/\(self.lastOCRMs ?? 0)ms(端到端) 语种=\(result.detectedLanguage ?? "nil")", AppLog.ax)
                guard !text.isEmpty else {
                    self.env.toast.show("没识别到文字，换一块区域再试", isError: true)
                    return
                }
                let anchor = CGRect(origin: NSEvent.mouseLocation, size: .zero)
                let opened = DispatchTime.now()
                self.env.card.presentOCR(text: text, anchor: anchor)
                let ms = Int((DispatchTime.now().uptimeNanoseconds - opened.uptimeNanoseconds) / 1_000_000)
                AppLog.echo("OCR 确认态出现（截图→卡片）耗时=\(ms)ms", AppLog.ax)
            } catch let error as AppError {
                if case .cancelled = error {
                    AppLog.echo("截图取消", AppLog.ax)
                } else {
                    self.env.toast.show(error.userMessage, isError: true, seconds: 3.6)
                }
            } catch {
                self.env.toast.show("截图失败：\(error.localizedDescription)", isError: true)
                AppLog.echo("截图失败：\(error)", AppLog.ax)
            }
        }
    }

    /// 收尾：显式 orderOut + 置空引用，不依赖 deinit。
    private func finishUp() {
        watchdog?.cancel()
        watchdog = nil
        retainedWindows.forEach { $0.orderOut(nil) }
        retainedWindows.removeAll()
        selector = nil
        retainedImage = nil
        isRunning = false
        startedAt = nil
        AppLog.echo("截图流程收尾：遮罩/截图引用已释放", AppLog.ax)
    }

    /// 看门狗：45s 还没收尾就强制复位（超时提示 + 允许下次热键继续用）。
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            AppLog.echo("截图流程超过 75s 未结束：强制复位", AppLog.ax)
            self.finishUp()
            self.env.toast.show("截图流程超时，已复位，可重新按热键", isError: true, seconds: 3.6)
        }
    }
}
