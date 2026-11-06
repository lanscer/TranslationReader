import Foundation

/// 历史记录的来源（文档 §6.7 history.source_kind）。
public enum SourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case selection
    case ocr
    case hotkey
    case clipboard
}

/// 一条历史记录，字段与文档 §6.7 的 history 表一一对应。
/// Store 负责持久化，OverlayKit / AppShell 只读它来渲染历史列表。
public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var createdAt: Int
    public var sourceText: String
    public var sourceLang: LangCode?
    public var targetLang: LangCode
    public var translation: String?
    public var detail: TranslationDetail?
    public var tier: AiTier?
    public var model: String?
    public var sourceKind: SourceKind
    public var appBundleID: String?
    public var ocrImagePath: String?
    public var error: String?

    public init(
        id: String,
        createdAt: Int,
        sourceText: String,
        sourceLang: LangCode? = nil,
        targetLang: LangCode = .zhHans,
        translation: String? = nil,
        detail: TranslationDetail? = nil,
        tier: AiTier? = nil,
        model: String? = nil,
        sourceKind: SourceKind = .selection,
        appBundleID: String? = nil,
        ocrImagePath: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.translation = translation
        self.detail = detail
        self.tier = tier
        self.model = model
        self.sourceKind = sourceKind
        self.appBundleID = appBundleID
        self.ocrImagePath = ocrImagePath
        self.error = error
    }
}
