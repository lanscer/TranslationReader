import AppKit
import Contracts
import OverlayKit
import SelectionKit

/// 划词监听（文档 §3.1）：5Hz 轮询 AX 选区，出现浮条；选中文本变化时刷新。
/// 未获辅助功能授权时不做轮询（AXIsProcessTrusted=false 读不到任何选区），只记一条日志。
@MainActor
final class SelectionWatcher {
    private unowned let env: AppEnvironment
    private var timer: Timer?
    private var bar: SelectionBarPanel?
    private var current: Selection?
    private var lastText: String = ""
    private var outsideMonitor: Any?
    private var axDisabledLogged = false

    private lazy var reader: AXSelectionReader? = SelectionKit.makeReader(
        configuration: SelectionConfiguration(),
        log: SelectionLog.defaultSink
    ).map { _ in AXSelectionReader() }

    init(env: AppEnvironment) {
        self.env = env
    }

    var isRunning: Bool { timer != nil }

    func start() {
        stop()
        AppLog.echo("划词监听启动（150–200ms 轮询）。辅助功能授权=\(PermissionCenter.accessibilityGranted)，屏幕录制=\(PermissionCenter.screenRecordingGranted)", AppLog.ax)
        guard PermissionCenter.accessibilityGranted else {
            AppLog.echo("AX 未授权：划词自动浮条不工作，⌥Space / 剪贴板 / 手动输入 三条路径仍可用", AppLog.ax)
            return
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideBar() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        outsideMonitor = nil
        hideBar()
    }

    func restartIfNeeded() {
        stop()
        start()
    }

    private func poll() {
        guard env.settings.settings.selection.enabled else {
            hideBar()
            return
        }
        var gate = SelectionGate(settings: env.settings.settings, ownBundleID: SingleInstanceLock.bundleIdentifier)
        gate.minimumCharacters = 2
        let selectionReader = AXSelectionReader(gate: gate)
        guard let selection = selectionReader.currentSelection() else {
            if current != nil {
                current = nil
                hideBar()
            }
            return
        }
        guard selection.text != lastText else { return }
        lastText = selection.text
        current = selection
        showBar(for: selection)
    }

    private func showBar(for selection: Selection) {
        let panel: SelectionBarPanel
        if let bar {
            panel = bar
        } else {
            let model = SelectionBarModel()
            panel = OverlayKit.makeSelectionBar(model: model)
            bar = panel
            wire(panel.model)
        }
        panel.model.present(selection)
        let placement = panel.present(selection: selection)
        AppLog.echo(String(format: "浮条出现 x=%.0f y=%.0f w=%.0f h=%.0f flippedH=%@ flippedV=%@",
                           placement.frame.minX, placement.frame.minY, placement.frame.width, placement.frame.height,
                           placement.flippedHorizontally ? "1" : "0", placement.flippedVertically ? "1" : "0"), AppLog.ax)
    }

    private func wire(_ model: SelectionBarModel) {
        model.onTranslate = { [weak self] in
            guard let self, let selection = self.current else { return }
            self.hideBar()
            self.env.card.present(text: selection.text, kind: .selection, anchor: selection.bounds, bundleID: selection.appBundleID)
        }
        model.onSpeak = { [weak self] in
            guard let self, let selection = self.current else { return }
            self.env.speech.toggle(selection.text)
            model.isSpeaking = self.env.speech.isSpeaking
        }
        model.onCopy = { [weak self] in
            guard let self, let selection = self.current else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selection.text, forType: .string)
            self.env.toast.show("原文已复制")
        }
        model.onFavorite = { [weak self] in
            guard let self, let selection = self.current else { return }
            self.env.toast.show("浮条收藏：整条记录会写进历史，可在历史窗口收藏")
            _ = selection
        }
        model.onAdvancedRetranslate = { [weak self] in
            guard let self, let selection = self.current else { return }
            self.hideBar()
            self.env.card.present(text: selection.text, kind: .selection, anchor: selection.bounds, bundleID: selection.appBundleID)
            self.env.card.session.switchTier(.advanced)
        }
        model.onDismiss = { [weak self] in self?.hideBar() }
    }

    private func hideBar() {
        bar?.dismiss()
        lastText = ""
    }
}
