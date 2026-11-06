import AppKit
import SwiftUI
import Contracts
import OverlayKit
import DesignSystem

/// 翻译卡窗口：语义与 OverlayKit.TranslationPanel 一致（nonactivating 但可成 key，Esc/⌘W 关闭，可拖动），
/// 落位复用 OverlayKit.OverlayLayout.cardPlacement（lead 的硬约束 1）。
@MainActor
final class TranslationCardPanel: NSPanel {
    static let defaultSize = CGSize(width: DSMetric.cardWidth, height: 320)
    static let lastOriginXKey = "card.lastOrigin.x"
    static let lastOriginYKey = "card.lastOrigin.y"

    let session: TranslationSession
    private let hostingView: NSHostingView<TranslationCardBody>

    init(session: TranslationSession, speech: SpeechCoordinator) {
        self.session = session
        self.hostingView = NSHostingView(rootView: TranslationCardBody(session: session, speech: speech))
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func configureWindow() {
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    var intrinsicSize: CGSize {
        let fitting = hostingView.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return Self.defaultSize }
        return CGSize(width: ceil(fitting.width), height: min(ceil(fitting.height), DSMetric.cardMaxHeight))
    }

    /// 位置：优先贴着选区；锚点为空时用上次位置（「记住上次位置」）。
    @discardableResult
    func present(anchor: CGRect) -> PanelPlacement {
        let size = intrinsicSize
        let screen = SelectionBarPanel.screen(containing: anchor) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let placement: PanelPlacement
        if anchor.isEmpty || (anchor.width == 0 && anchor.height == 0) {
            let defaults = UserDefaults.standard
            let savedOrigin = CGPoint(
                x: defaults.double(forKey: Self.lastOriginXKey),
                y: defaults.double(forKey: Self.lastOriginYKey)
            )
            let saved = CGRect(origin: savedOrigin, size: size)
            if savedOrigin != .zero, visible.insetBy(dx: 20, dy: 20).intersects(saved) {
                placement = PanelPlacement(frame: saved)
            } else {
                placement = OverlayLayout.cardPlacement(selection: anchor, size: size, screenVisibleFrame: visible)
            }
        } else {
            placement = OverlayLayout.cardPlacement(selection: anchor, size: size, screenVisibleFrame: visible)
        }

        setFrame(placement.frame, display: true)
        orderFrontRegardless()
        makeKey()
        AppLog.echo(String(format: "卡片落位 x=%.0f y=%.0f w=%.0f h=%.0f", placement.frame.minX, placement.frame.minY, placement.frame.width, placement.frame.height), AppLog.ui)
        return placement
    }

    /// 内容变化后按顶边锚定重排（卡片向下生长，不跳动）。
    func refreshSizeKeepingTop() {
        let size = intrinsicSize
        var frame = self.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        setFrame(frame, display: true)
    }

    func rememberOrigin() {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: Self.lastOriginXKey)
        defaults.set(Double(frame.origin.y), forKey: Self.lastOriginYKey)
    }

    func dismiss() {
        rememberOrigin()
        orderOut(nil)
    }

    // MARK: Esc / ⌘W

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCloseShortcut(event) {
            session.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        session.close()
    }

    override func keyDown(with event: NSEvent) {
        if Self.isEscape(event) || Self.isCloseShortcut(event) {
            session.close()
            return
        }
        super.keyDown(with: event)
    }

    static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53
    }

    static func isCloseShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
