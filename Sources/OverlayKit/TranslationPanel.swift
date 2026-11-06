import AppKit
import Contracts
import DesignSystem
import SwiftUI

/// 文档 §3.2 / §6.2：翻译弹窗。同样 nonactivating（不激活 App、不抢前台），
/// 但**允许**成为 key window 以便选中原文/译文；Esc 与 ⌘W 关闭。
@MainActor
public final class TranslationPanel: NSPanel {
    public static let defaultSize = CGSize(width: DSMetric.cardWidth, height: 320)

    public let model: TranslationCardModel
    private let hostingView: NSHostingView<TranslationCardView>

    public init(model: TranslationCardModel) {
        self.model = model
        self.hostingView = NSHostingView(rootView: TranslationCardView(model: model))
        super.init(
            contentRect: CGRect(origin: .zero, size: TranslationPanel.defaultSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        contentView = hostingView
    }

    public override var canBecomeKey: Bool { true }

    public override var canBecomeMain: Bool { false }

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

    /// 出现在选区右侧；贴边自动翻转（文档 §6.2）。
    @discardableResult
    public func present(selectionBounds: CGRect, screen: NSScreen? = nil) -> PanelPlacement {
        let size = intrinsicSize
        let targetScreen = screen ?? SelectionBarPanel.screen(containing: selectionBounds)
        let placement = OverlayLayout.cardPlacement(
            selection: selectionBounds,
            size: size,
            screenVisibleFrame: targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        setFrame(placement.frame, display: true)
        orderFrontRegardless()
        return placement
    }

    public func dismiss() {
        orderOut(nil)
    }

    public var intrinsicSize: CGSize {
        let fitting = hostingView.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return TranslationPanel.defaultSize }
        return CGSize(
            width: ceil(fitting.width),
            height: min(ceil(fitting.height), DSMetric.cardMaxHeight)
        )
    }

    // MARK: - Esc / ⌘W

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCloseShortcut(event) {
            model.onClose()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        model.onClose()
    }

    public override func keyDown(with event: NSEvent) {
        if Self.isEscape(event) || Self.isCloseShortcut(event) {
            model.onClose()
            return
        }
        super.keyDown(with: event)
    }

    public static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53
    }

    public static func isCloseShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isW = event.charactersIgnoringModifiers?.lowercased() == "w"
        return flags.contains(.command) && isW
    }
}
