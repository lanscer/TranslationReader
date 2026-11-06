import AppKit
import Combine
import Contracts

/// 卡片生命周期：一个进程只有一个卡片（lead 硬约束 2）。
@MainActor
final class CardController {
    private unowned let env: AppEnvironment
    let session: TranslationSession
    private var panel: TranslationCardPanel?
    private var blurObserver: NSObjectProtocol?
    private var resizeCancellable: AnyCancellable?
    private(set) var lastPresentedAt: Date?

    init(env: AppEnvironment) {
        self.env = env
        self.session = TranslationSession(env: env)
        session.onRequestClose = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(text: String, kind: SourceKind, anchor: CGRect, editable: Bool = false, bundleID: String? = nil) {
        lastPresentedAt = Date()
        let panel = ensurePanel()
        panel.dismiss()
        session.present(text: text, kind: kind, editable: editable, bundleID: bundleID)
        panel.present(anchor: anchor)
        watchBlur(of: panel)
    }

    /// OCR 路径：只开确认态，不自动翻译（确认后才翻译 + 朗读）。
    func presentOCR(text: String, anchor: CGRect) {
        present(text: text, kind: .ocr, anchor: anchor, editable: true)
    }

    func hide() {
        session.cancel()
        env.speech.stop()
        panel?.dismiss()
        removeBlurWatch()
    }

    func showSettings() {
        env.settingsWindow.show(selecting: .account)
    }

    private func ensurePanel() -> TranslationCardPanel {
        if let panel { return panel }
        let created = TranslationCardPanel(session: session, speech: env.speech)
        panel = created
        resizeCancellable = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    self.panel?.refreshSizeKeepingTop()
                }
            }
        return created
    }

    private func watchBlur(of panel: TranslationCardPanel) {
        removeBlurWatch()
        blurObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                guard self.env.settings.settings.general.closeOnBlur else { return }
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard let current = self.panel, !current.isKeyWindow, current.isVisible else { return }
                _ = panel
                AppLog.echo("卡片失焦关闭", AppLog.ui)
                self.hide()
            }
        }
    }

    private func removeBlurWatch() {
        if let blurObserver {
            NotificationCenter.default.removeObserver(blurObserver)
        }
        blurObserver = nil
    }
}
