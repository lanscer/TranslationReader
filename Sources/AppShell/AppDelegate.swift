import Foundation
import AppKit
import SwiftUI
import Contracts
import OCRVision

/// 冷启动计时（文档 §9 M0：冷启动到菜单栏可用）。
enum LaunchClock {
    static let start = Date()

    static func elapsedMs() -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didBootstrap = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { handleLaunch() }
    }

    @MainActor
    private func handleLaunch() {
        installCrashHandler()
        NSApp.setActivationPolicy(.accessory)

        guard SingleInstanceLock.shared.acquire() else {
            AppLog.echo("已有实例在运行，新实例退出", AppLog.lifecycle)
            exit(0)
        }

        // 验收模式：--selftest / --render-evidence 自己管理退出。
        if SelfTest.handleCommandLine() { return }

        bootstrap()
    }

    @MainActor
    private func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        let env = AppEnvironment.shared
        AppLog.echo("TranslationReader 启动（版本 \(Self.version)）", AppLog.lifecycle)
        // 第一行就给出现场：版本 / bundle / 签名身份 / TCC 状态（不读钥匙串，避免启动即弹窗）。
        AppLog.snapshotEnvironment(version: Self.version)

        env.settings.refreshAPIKeyState()
        env.hotkeys.registerAll()
        env.selectionWatcher.start()
        env.permissions.refresh()

        NotificationCenter.default.addObserver(
            forName: .hotkeysChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AppEnvironment.shared.hotkeys.registerAll() }
        }

        // Vision 首次识别实测 29.9s，必须启动后立刻在后台预热（文档 §6.3）。
        // 验收需要量化预热对常驻内存的影响，故留一个只读开关：TRANSLATIONREADER_NO_PREWARM=1 时跳过。
        if ProcessInfo.processInfo.environment["TRANSLATIONREADER_NO_PREWARM"] != "1" {
            // 预热用 userInitiated + activity 抑制 App Nap：后台任务被系统挂起时，
            // Vision 的模型加载会一直占着串行队列，截图 OCR 就会一直排队（用户侧表现是「卡死」）。
            Task.detached(priority: .userInitiated) {
                let ms = await OCRVision.warmUp()
                AppLog.echo("Vision OCR 预热完成：\(ms)ms（此后单次识别约 0.4–1s）", AppLog.lifecycle)
            }
        }
        AppLog.echo("Vision OCR 预热已触发（OCRVision.warmUp，AppDelegate.bootstrap）", AppLog.lifecycle)

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let ms = LaunchClock.elapsedMs()
                AppLog.echo("冷启动到菜单栏可用（didFinishLaunching + 首帧）：\(ms)ms", AppLog.lifecycle)
                let statusWindows = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
                AppLog.echo("菜单栏状态项自检：NSApp.windows 共 \(NSApp.windows.count) 个，其中状态栏窗 \(statusWindows.count) 个 -> "
                            + NSApp.windows.map { String(describing: type(of: $0)) }.joined(separator: ","), AppLog.lifecycle)
                AppLog.echo("首帧完成：菜单栏已就绪", AppLog.ui)
                self.showFirstRunGuideIfNeeded()
            }
        }
    }

    /// 首次启动若缺权限，主动给一张引导卡（文档 §4.3「未授权」分支）。
    @MainActor
    private func showFirstRunGuideIfNeeded() {
        let key = "general.didShowPermissionGuide"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !PermissionCenter.accessibilityGranted || !PermissionCenter.screenRecordingGranted else { return }
        AppEnvironment.shared.permissions.show()
    }

    /// 崩溃兜底：未捕获异常直接落 app.log（[crash] 标签），下次启动就能看到现场。
    /// 用非 AppLog 路径，避免在异常态里再做 os_log/锁操作。
    private func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let stack = exception.callStackSymbols.prefix(12).joined(separator: " ← ")
            FileLogSink.shared.write(tag: "crash", message: "未捕获异常 \(name): \(reason) | \(stack)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            let env = AppEnvironment.shared
            env.hotkeys.unregisterAll()
            env.selectionWatcher.stop()
            env.card.hide()
            AppLog.echo("退出前状态：卡片可见=\(env.card.isVisible ? "是" : "否") 朗读中=\(env.speech.isSpeaking ? "是" : "否") 历史=\(env.recentEntries(limit: 1000).count) 条", AppLog.lifecycle)
            AppLog.echo("TranslationReader 退出", AppLog.lifecycle)
        }
    }

    @objc func showSettingsWindow() {
        MainActor.assumeIsolated {
            AppEnvironment.shared.settingsWindow.show(selecting: .account)
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
