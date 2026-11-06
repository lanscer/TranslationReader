import AppKit
import Contracts
import DesignSystem

/// 文档 §5.2 / §6.2：浮条与弹窗窗口模块。只依赖 Contracts + DesignSystem；
/// 翻译与朗读通过注入的回调接进来，本模块不认识 TranslateKit / SpeechKit。
public enum OverlayKit {
    public static let moduleName = "OverlayKit"

    public enum PanelKind: String, Sendable {
        case selectionBar
        case translationCard
    }

    /// 供 AppShell 引用的尺寸（真实 token 在 DesignSystem）。
    public static let cardSize = CGSize(width: DSMetric.cardWidth, height: DSMetric.cardMaxHeight)

    /// 弹窗渲染所需的共享契约（可见性自检用）。
    public static let declaredContracts = ["Selection", "TranslationDetail", "AppError"]

    @MainActor
    public static func makeSelectionBar() -> SelectionBarPanel {
        SelectionBarPanel(model: SelectionBarModel())
    }

    @MainActor
    public static func makeSelectionBar(model: SelectionBarModel) -> SelectionBarPanel {
        SelectionBarPanel(model: model)
    }

    @MainActor
    public static func makeTranslationCard() -> TranslationPanel {
        TranslationPanel(model: TranslationCardModel())
    }

    @MainActor
    public static func makeTranslationCard(model: TranslationCardModel) -> TranslationPanel {
        TranslationPanel(model: model)
    }
}
