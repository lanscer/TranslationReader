import AppKit
import SwiftUI
import DesignSystem

/// 轻量 toast：右上角浮层，2.4s 自动消失。引擎回落、复制成功、导出完成等都走这里。
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var isError: Bool = false
    @Published private(set) var shownAt: Date = .distantPast

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, isError: Bool = false, seconds: Double = 2.4) {
        message = text
        self.isError = isError
        shownAt = Date()
        present()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
        AppLog.echo("toast: " + text, AppLog.lifecycle)
    }

    func hide() {
        message = nil
        panel?.orderOut(nil)
    }

    private func present() {
        if panel == nil {
            let p = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 280, height: 44),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.isFloatingPanel = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            panel = p
        }
        guard let panel, let message else { return }
        panel.contentView = NSHostingView(rootView: ToastBanner(text: message, isError: isError))
        let fitting = panel.contentView?.fittingSize ?? CGSize(width: 280, height: 44)
        let width = min(max(fitting.width, 160), 420)
        let height = max(fitting.height, 34)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: screen.midX - width / 2, y: screen.maxY - height - 12)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }
}
