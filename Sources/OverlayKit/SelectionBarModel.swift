import Combine
import Contracts
import Foundation

/// 浮条内容的注入面：原文文本 + 翻译/朗读/复制/收藏/高级重译回调 + 关闭回调。
/// 不依赖 TranslateKit / SpeechKit —— 翻译与朗读由 AppShell 通过回调注入。
@MainActor
public final class SelectionBarModel: ObservableObject {
    @Published public var sourceText: String
    @Published public var appBundleID: String
    @Published public var isSpeaking: Bool
    @Published public var isTranslating: Bool
    @Published public var isFavorited: Bool

    public var onTranslate: () -> Void
    public var onSpeak: () -> Void
    public var onCopy: () -> Void
    public var onFavorite: () -> Void
    public var onAdvancedRetranslate: () -> Void
    public var onDismiss: () -> Void

    public init(
        sourceText: String = "",
        appBundleID: String = "",
        isSpeaking: Bool = false,
        isTranslating: Bool = false,
        isFavorited: Bool = false,
        onTranslate: @escaping () -> Void = {},
        onSpeak: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {},
        onFavorite: @escaping () -> Void = {},
        onAdvancedRetranslate: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) {
        self.sourceText = sourceText
        self.appBundleID = appBundleID
        self.isSpeaking = isSpeaking
        self.isTranslating = isTranslating
        self.isFavorited = isFavorited
        self.onTranslate = onTranslate
        self.onSpeak = onSpeak
        self.onCopy = onCopy
        self.onFavorite = onFavorite
        self.onAdvancedRetranslate = onAdvancedRetranslate
        self.onDismiss = onDismiss
    }

    /// 每次浮条出现时刷新注入内容。
    public func present(_ selection: Selection) {
        sourceText = selection.text
        appBundleID = selection.appBundleID
        isTranslating = false
    }
}
