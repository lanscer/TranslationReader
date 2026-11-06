import AppKit
import Contracts
import DesignSystem
import SwiftUI

/// 文档 §3.1 / §6.2：划词浮条窗口。
/// styleMask = [.nonactivatingPanel, .borderless]；level = .statusBar；
/// collectionBehavior 含 canJoinAllSpaces / fullScreenAuxiliary；
/// canBecomeKey = false，且**只** orderFrontRegardless()，绝不 makeKeyAndOrderFront。
@MainActor
public final class SelectionBarPanel: NSPanel {
    public static let defaultSize = CGSize(width: 156, height: 32)

    public let model: SelectionBarModel
    private let hostingView: NSHostingView<SelectionBarView>

    public init(model: SelectionBarModel) {
        self.model = model
        self.hostingView = NSHostingView(rootView: SelectionBarView(model: model))
        super.init(
            contentRect: CGRect(origin: .zero, size: SelectionBarPanel.defaultSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        contentView = hostingView
    }

    public override var canBecomeKey: Bool { false }

    public override var canBecomeMain: Bool { false }

    private func configureWindow() {
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
    }

    /// 内容自适应尺寸（SwiftUI fittingSize），拿不到就退回默认尺寸。
    public var intrinsicSize: CGSize {
        let fitting = hostingView.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return SelectionBarPanel.defaultSize }
        return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
    }

    /// 出现在选区右上角 +8pt 处并返回实际落位（验收取证用）。
    @discardableResult
    public func present(selection: Selection, screen: NSScreen? = nil) -> PanelPlacement {
        model.present(selection)
        return present(bounds: selection.bounds, screen: screen)
    }

    @discardableResult
    public func present(bounds: CGRect, screen: NSScreen? = nil) -> PanelPlacement {
        let size = intrinsicSize
        let targetScreen = screen ?? Self.screen(containing: bounds)
        let placement = OverlayLayout.barPlacement(
            selection: bounds,
            size: size,
            screenVisibleFrame: targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
            offset: DSMetric.selectionBarOffset
        )
        setFrame(placement.frame, display: true)
        orderFrontRegardless()
        return placement
    }

    public func dismiss() {
        orderOut(nil)
    }

    /// 文档 §6.2：多屏时取包含选区的屏。
    public static func screen(containing bounds: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let index = OverlayLayout.screenIndex(containing: bounds, screens: screens.map { $0.frame })
        return screens[min(index ?? 0, screens.count - 1)]
    }
}
