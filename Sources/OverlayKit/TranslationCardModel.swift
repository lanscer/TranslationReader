import Combine
import Contracts
import Foundation

/// 翻译卡内容的注入面：原文文本、喇叭按钮回调、译文文本、关闭回调，
/// 外加语言方向/模型档位等展示字段。不依赖 TranslateKit / SpeechKit。
@MainActor
public final class TranslationCardModel: ObservableObject {
    @Published public var sourceText: String
    @Published public var translationText: String
    @Published public var languagePairTitle: String
    @Published public var tier: AiTier
    @Published public var isSpeaking: Bool
    @Published public var isStreaming: Bool
    @Published public var errorText: String?

    public var onSpeak: () -> Void
    public var onClose: () -> Void
    public var onCopyTranslation: () -> Void
    public var onRegenerate: () -> Void
    public var onTierChange: (AiTier) -> Void

    public init(
        sourceText: String = "",
        translationText: String = "",
        languagePairTitle: String = "自动检测 · 中文",
        tier: AiTier = .standard,
        isSpeaking: Bool = false,
        isStreaming: Bool = false,
        errorText: String? = nil,
        onSpeak: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onCopyTranslation: @escaping () -> Void = {},
        onRegenerate: @escaping () -> Void = {},
        onTierChange: @escaping (AiTier) -> Void = { _ in }
    ) {
        self.sourceText = sourceText
        self.translationText = translationText
        self.languagePairTitle = languagePairTitle
        self.tier = tier
        self.isSpeaking = isSpeaking
        self.isStreaming = isStreaming
        self.errorText = errorText
        self.onSpeak = onSpeak
        self.onClose = onClose
        self.onCopyTranslation = onCopyTranslation
        self.onRegenerate = onRegenerate
        self.onTierChange = onTierChange
    }

    /// 新一次翻译开始时重置流式状态（译文逐字追加由 AppShell 改写 translationText）。
    public func begin(sourceText: String, pairTitle: String? = nil) {
        self.sourceText = sourceText
        translationText = ""
        isStreaming = true
        errorText = nil
        if let pairTitle {
            languagePairTitle = pairTitle
        }
    }

    public func append(_ delta: String) {
        translationText += delta
    }

    public func finish() {
        isStreaming = false
    }
}
